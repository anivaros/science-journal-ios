/*
 *  Copyright 2019 Google Inc. All Rights Reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

import ImageIO
import MobileCoreServices
import UIKit

import third_party_objective_c_material_components_ios_components_Palettes_Palettes
import third_party_sciencejournal_ios_ScienceJournalProtos

// MARK: - MetadataManagerError

/// Metadata errors.
enum MetadataManagerError: Error {
  /// The file being opened has a version too new for this build.
  case openingFileWithNewerVersion(Int32?)
  /// The file being saved has a version too new for this build.
  case savingFileWithNewerVersion

  var logString: String {
    switch self {
    case .openingFileWithNewerVersion(let newerVersion):
      return "Attempting to upgrade a file that has a version " +
          "(\(String(describing: newerVersion))) newer than the latest supported by this build."
    case .savingFileWithNewerVersion:
      return "Attempting to save a file with a version newer than the current build."
    }
  }
}

extension Notification.Name {
  /// Posted when an asset is deleted when the cover image is set and the previous cover image is no
  /// longer in use by the experiment.
  static let metadataManagerDeletedCoverImageAsset =
      NSNotification.Name("MetadataManagerDeletedCoverImageAsset")
}

/// Stores experiment and trial metadata for Science Journal.
public class MetadataManager {

  // MARK: - Constants

  /// The name of the experiment proto in Science Journal document files.
  static let experimentProtoFilename = "experiment.proto"
  /// The name of the sensor data proto in Science Journal document files.
  static let sensorDataProtoFilename = "sensorData.proto"
  /// The name of the assets directory in experiment directories and Science Journal document files.
  static let assetsDirectoryName = "assets"
  /// When the notification `metadataManagerDeletedCoverImageAsset` is posted, this is the key for
  /// the experiment ID in `userInfo`.
  static let deletedCoverImageAssetExperimentIDKey =
      "MetadataManagerDeletedCoverImageAssetExperimentIDKey"
  /// When the notification `metadataManagerDeletedCoverImageAsset` is posted, this is the key for
  /// the file path of the image asset deleted in `userInfo`.
  static let deletedCoverImageAssetFilePathKey = "MetadataManagerDeletedCoverImageAssetFilePathKey"

  /// The filename of the experiment cover image asset used for import and export.
  static let importExportCoverImageFilename = "ExperimentCoverImage.jpg"

  /// The pre-auth legacy root directory.
  private static let scienceJournalDirectoryName = "Science Journal"

  let bluetoothSensorsDirectoryName = "bluetoothSensors"
  let experimentsDirectoryName = "experiments"
  let deletedAssetsDirectoryName = "DeletedAssets"
  let deletedDataDirectoryName = "DeletedData"
  private let documentFileExtension = "sj"

  // MARK: - Properties

  // The clock used for last used dates.
  var clock = Clock()

  /// The root directory to which all other paths are relative.
  public let rootURL: URL

  /// The root directory to which all deleted paths are relative.
  let deletedRootURL: URL

  // This is a legacy directory, replaced by `deletedDataDirectory`. When removing all deleted data,
  // this directory must also be deleted.
  lazy var deletedAssetsDirectoryURL: URL = {
    return self.deletedRootURL.appendingPathComponent(self.deletedAssetsDirectoryName)
  }()

  /// The deleted data directory.
  lazy var deletedDataDirectoryURL: URL = {
    return self.deletedRootURL.appendingPathComponent(self.deletedDataDirectoryName)
  }()

  /// The deleted experiments directory.
  lazy var deletedExperimentsDirectoryURL: URL = {
    return self.deletedDataDirectoryURL.appendingPathComponent(self.experimentsDirectoryName)
  }()

  /// The experiments directory.
  private(set) lazy var experimentsDirectoryURL: URL = {
    return self.rootURL.appendingPathComponent(self.experimentsDirectoryName)
  }()

  /// The bluetooth sensor spec directory.
  private lazy var bluetoothSensorsDirectoryURL: URL = {
    return self.rootURL.appendingPathComponent(self.bluetoothSensorsDirectoryName)
  }()

  private lazy var experimentLibraryURL: URL = {
    return self.rootURL.appendingPathComponent(Constants.Drive.experimentLibraryProtoFilename)
  }()

  private lazy var localSyncStatusURL: URL = {
    return self.rootURL.appendingPathComponent("local_sync_status.proto")
  }()

  /// Versions 2.X and earlier did not use experiment's imagePath field. Therefore all imported and
  /// exported experiments rely on a specially named file to identify the experiment cover image.
  var importExportCoverImagePath: String {
    return URL(fileURLWithPath: MetadataManager.assetsDirectoryName)
        .appendingPathComponent(MetadataManager.importExportCoverImageFilename).path
  }

  // An operation queue.
  private let operationQueue = GSJOperationQueue()

  // Save queues.
  private let userMetadataSaveQueue =
      DispatchQueue(label: "com.google.ScienceJournal.MetadataManager.UserMetadataSave")
  private let experimentLibrarySaveQueue =
      DispatchQueue(label: "com.google.ScienceJournal.MetadataManager.ExperimentLibrarySave")
  private let localSyncStatusSaveQueue =
      DispatchQueue(label: "com.google.ScienceJournal.MetadataManager.LocalSyncStatusSave")

  private let preferenceManager: PreferenceManager
  private let sensorController: SensorController
  private let sensorDataManager: SensorDataManager
  private var userMetadata: UserMetadata!
  private let userMetadataURL: URL

  // MARK: - Public

  /// Designated initializer.
  ///
  /// - Parameters:
  ///   - rootURL: The root URL for storing files to disk.
  ///   - deletedRootURL: The URL root where deleted files are moved before being deleted. This
  ///                     parameter exists to support the pre-auth root user which moved deleted
  ///                     files to a different location.
  ///   - preferenceManager: The preference manager.
  ///   - sensorController: The sensor controller.
  ///   - sensorDataManager: The sensor data manager.
  init(rootURL: URL,
       deletedRootURL: URL,
       preferenceManager: PreferenceManager,
       sensorController: SensorController,
       sensorDataManager: SensorDataManager) {
    self.rootURL = rootURL
    self.deletedRootURL = deletedRootURL
    self.preferenceManager = preferenceManager
    self.sensorController = sensorController
    self.sensorDataManager = sensorDataManager
    userMetadataURL = rootURL.appendingPathComponent("user_metadata")
    configureUserMetadata()
  }

  /// Convenience initializer that sets the documents URL as the root URL.
  ///
  /// - Parameters:
  ///   - preferenceManager: The preference manager.
  ///   - sensorDataManager: The sensor data manager.
  convenience init(preferenceManager: PreferenceManager,
                   sensorController: SensorController,
                   sensorDataManager: SensorDataManager) {
    let documentsURL = URL.documentsDirectoryURL
    let rootURL = documentsURL.appendingPathComponent(MetadataManager.scienceJournalDirectoryName)
    self.init(rootURL: rootURL,
              deletedRootURL: documentsURL,
              preferenceManager: preferenceManager,
              sensorController: sensorController,
              sensorDataManager: sensorDataManager)

    // Register for trial stats update notifications.
    NotificationCenter.default.addObserver(self,
        selector: #selector(handleTrialStatsDidCompleteNotification(notification:)),
        name: SensorDataManager.TrialStatsCalculationDidComplete,
        object: nil)
  }

  /// Returns the assets directory URL for a specific experiment.
  ///
  /// - Parameter experiment: An experiment.
  /// - Returns: A directory URL.
  func assetsURL(for experiment: Experiment) -> URL {
    return experimentDirectoryURL(for: experiment.ID)
        .appendingPathComponent(MetadataManager.assetsDirectoryName)
  }

  /// Do any needed work in preparation of the user session ending.
  func tearDown() {
    operationQueue.terminate()
  }

  // MARK: - Notifications

  @objc private func handleTrialStatsDidCompleteNotification(notification: Notification) {
    let experimentIDKey = SensorDataManager.TrialStatsDidCompleteExperimentIDKey
    let trialIDKey = SensorDataManager.TrialStatsDidCompleteTrialIDKey
    let statsKey = SensorDataManager.TrialStatsDidCompleteTrialStatsKey
    guard let experimentID = notification.userInfo?[experimentIDKey] as? String,
        let trialID = notification.userInfo?[trialIDKey] as? String,
        let trialStats = notification.userInfo?[statsKey] as? [TrialStats] else {
      return
    }

    // Update the trial and save the experiment.
    if let experiment = self.experiment(withID: experimentID),
        let trial = experiment.trial(withID: trialID) {
      trial.trialStats = trialStats
      saveExperiment(experiment)
    }
  }

  // MARK: - ExperimentOverview

  /// An array of experiment overviews. The overviews contain all the information necessary to
  /// display a list of experiments without having to load the actual experiments.
  public var experimentOverviews: [ExperimentOverview] {
    return userMetadata.experimentOverviews
  }

  /// Returns an experiment and its overview for a given experiment ID.
  ///
  /// - Parameter experimentID: An experiment ID.
  /// - Returns: The experiment and overview.
  public func experimentAndOverview(forExperimentID experimentID: String) ->
      (experiment: Experiment, overview: ExperimentOverview)? {
    guard let overview = userMetadata.experimentOverview(with: experimentID),
        let experiment = experiment(withID: experimentID) else {
      return nil
    }
    return (experiment, overview)
  }

  /// Adds an experiment and its overview. The experiment version will not be validated.
  ///
  /// - Parameters:
  ///   - experiment: An experiment.
  ///   - overview: The experiment's overview.
  /// - Returns: True if adding the experiment and overview was successful.
  @discardableResult func addExperiment(_ experiment: Experiment,
                                        overview: ExperimentOverview) -> Bool {
    let saveExperimentSuccess = saveExperiment(experiment, validateVersion: false)
    if saveExperimentSuccess {
      userMetadata.addExperimentOverview(overview)
      saveUserMetadata()
      registerNewLocalExperiment(withID: experiment.ID, isArchived: overview.isArchived)
    }
    return saveExperimentSuccess
  }

  /// Updates an overview to reflect the given experiment's data. If the overview does not exist,
  /// this method does nothing.
  ///
  /// - Parameters:
  ///   - experiment: The experiment in the overview.
  ///   - updateLastUsedDate: Should the last used date be updated to now? Defaults to true.
  private func updateOverview(for experiment: Experiment, updateLastUsedDate: Bool = true) {
    guard let overview = userMetadata.experimentOverview(with: experiment.ID) else {
      return
    }

    overview.title = experiment.title
    if updateLastUsedDate {
      overview.lastUsedDate = clock.now
    }
    overview.trialCount = experiment.trials.count
    if let experimentImagePath = experiment.imagePath {
      overview.imagePath = experimentImagePath
    }
    saveUserMetadata()
  }

  /// Updates an experiment overview with the provided image path if the overview currently doesn't
  /// have an image path set.
  ///
  /// - Parameters:
  ///   - imagePath: An image path.
  ///   - experiment: An experiment.
  func updateCoverImageForAddedImageIfNeeded(imagePath: String, experiment: Experiment) {
    // Check experiment overview image
    guard let overview = userMetadata.experimentOverview(with: experiment.ID),
        overview.imagePath == nil else {
      return
    }

    // Overview image was nil, so set it to the newly added image path.
    saveCoverImagePath(imagePath, forOverview: overview, experiment: experiment)
  }

  /// Updates an experiment overview image given that the image path has been removed from the
  /// experiment. Sets the overview image to another picture note if available, otherwise nil.
  ///
  /// - Parameters:
  ///   - imagePath: An image path.
  ///   - experiment: An experiment.
  /// - Returns: A block that will undo the overview image change if executed.
  func updateCoverImageForRemovedImageIfNeeded(imagePath: String,
                                               experiment: Experiment) -> () -> Void {
    // Compare image path to overview image path
    guard let overview = userMetadata.experimentOverview(with: experiment.ID),
        overview.imagePath == imagePath else {
      return {}
    }

    // The overview's image was deleted, so look for another picture note.
    let newImagePath = nextImagePathFromPictureNotes(experiment)
    saveCoverImagePath(newImagePath, forOverview: overview, experiment: experiment)

    return {
      self.saveCoverImagePath(imagePath, forOverview: overview, experiment: experiment)
    }
  }

  /// Updates an experiment overview image given that the image path has been removed from the
  /// experiment. Sets the overview image to another picture note if available, otherwise nil.
  ///
  /// Not undoable. If you need an undo action, use `updateCoverImageForRemovedImageIfNeeded`.
  ///
  /// - Parameters:
  ///   - imagePath: An image path.
  ///   - experiment: An experiment.
  func updateCoverImageForRemovedImageIfNeededWithoutUndo(imagePath: String,
                                                          experiment: Experiment) {
    _ = updateCoverImageForRemovedImageIfNeeded(imagePath: imagePath,
                                                experiment: experiment)
  }

  /// Removes a cover image for an experiment.
  ///
  /// - Parameter experiment: The experiment.
  /// - Returns: True if successful, false if not.
  func removeCoverImageForExperiment(_ experiment: Experiment) -> Bool {
    guard let overview = userMetadata.experimentOverview(with: experiment.ID) else {
      return false
    }

    // Some versions of the app only stored cover image paths in the overview. If a cover image
    // is set, delete it.
    if let coverImagePath = experiment.imagePath ?? overview.imagePath {
      deleteAssetAtPath(coverImagePath, experimentID: experiment.ID)
    }

    overview.imagePath = nil
    experiment.imagePath = nil
    saveUserMetadata()
    return true
  }

  /// Removes the overview for an experiment with a matching ID.
  ///
  /// - Parameter experimentID: An experiment ID.
  /// - Returns: The removed overview.
  @discardableResult func removeOverview(
      forExperimentID experimentID: String) -> ExperimentOverview? {
    let removedOverview = userMetadata.removeExperimentOverview(with: experimentID)
    saveUserMetadata()
    return removedOverview
  }

  /// Adds an overview.
  ///
  /// - Parameter experimentOverview: An experiment overview.
  func addOverview(_ experimentOverview: ExperimentOverview) {
    userMetadata.addExperimentOverview(experimentOverview)
    saveUserMetadata()
  }

  // MARK: - Experiments

  /// Gets the experiment for an ID.
  ///
  /// - Parameter experimentID: The experiment ID.
  /// - Returns: An experiment.
  public func experiment(withID experimentID: String) -> Experiment? {
    let experimentURL = experimentProtoURL(for: experimentID)
    return experiment(atURL: experimentURL, withID: experimentID)
  }

  /// Gets the experiment at a URL with an ID. Use this only when reading experiments outside of
  /// the experiments directory.
  ///
  /// - Parameters:
  ///   - url: The url of the experiment directory to open.
  ///   - experimentID: The ID to assign to the opened experiment.
  /// - Returns: An experiment.
  func experiment(atURL url: URL, withID experimentID: String) -> Experiment? {
    guard let data = try? Data(contentsOf: url) else {
      return nil
    }

    let proto: GSJExperiment
    do {
      proto = try GSJExperiment.parse(from: data)
    } catch {
      print("[MetadataManager] Error parsing experiment: \(error)")
      return nil
    }

    // Check the file version to see if it's supported.
    guard canOpenExperimentVersion(proto) else {
      return nil
    }

    let experiment = Experiment(proto: proto, ID: experimentID)

    do {
      try upgradeExperimentVersionIfNeeded(experiment)
      return experiment
    } catch let error as MetadataManagerError {
      print("[MetadataManager] Error upgrading experiment: \(error.logString)")
    } catch {
      print("[MetadataManager] Error upgrading experiment: \(error)")
    }
    return nil
  }

  /// Gets the sensor data proto at a URL.
  ///
  /// - Parameter url: The location of the sensor data proto file.
  /// - Returns: A sensor data proto.
  func readSensorDataProto(atURL url: URL) -> GSJScalarSensorData? {
    do {
      let data = try Data(contentsOf: url)
      let proto = try GSJScalarSensorData.parse(from: data)
      return proto
    } catch {
      print("[MetadataManager] Error opening GSJScalarSensorData proto: \(error)")
    }
    return nil
  }

  /// Creates a new experiment and saves it to disk.
  ///
  /// - Parameter title: The experiment title.
  /// - Returns: The created experiment and its associated overview.
  func createExperiment(withTitle title: String? = nil) -> (Experiment, ExperimentOverview) {
    let experimentID = UUID().uuidString
    let overview = ExperimentOverview(experimentID: experimentID)

    let colorPalette = MDCPalette.nextExperimentListCardColorPalette(withUsedPalettes:
        experimentOverviews.map { $0.colorPalette })
    overview.colorPalette = colorPalette
    overview.title = title
    userMetadata.addExperimentOverview(overview)
    saveUserMetadata()

    let experiment = Experiment(ID: experimentID)
    experiment.setTitle(title, withChange: false)

    // Create experiment with latest known version.
    experiment.fileVersion = FileVersion(major: Experiment.Version.major,
                                         minor: Experiment.Version.minor,
                                         platform: Experiment.Version.platform)

    saveExperiment(experiment)

    registerNewLocalExperiment(withID: experimentID)

    return (experiment, overview)
  }

  /// Creates an overview for an experiment with the given ID and adds it to user metadata. This
  /// assumes an experiment with the given ID already exists in the experiments folder.
  ///
  /// - Parameter experimentID: An experiment ID.
  func addImportedExperiment(withID experimentID: String) {
    guard let experiment = self.experiment(withID: experimentID) else {
      return
    }

    let overview = ExperimentOverview(experimentID: experimentID)
    overview.colorPalette = MDCPalette.nextExperimentListCardColorPalette(withUsedPalettes:
        experimentOverviews.map { $0.colorPalette })

    // For importing, the experiment's imagePath is ignored in favor of the named cover image file.
    // Versions 2.X and earlier do not support imagePath so this maintains consistency across all
    // versions of the app.
    let coverURL =
        experimentDirectoryURL(for: experimentID).appendingPathComponent(importExportCoverImagePath)
    if FileManager.default.fileExists(atPath: coverURL.path) {
      overview.imagePath = importExportCoverImagePath
      experiment.imagePath = importExportCoverImagePath
    } else {
      overview.imagePath = nil
      experiment.imagePath = nil
    }

    userMetadata.addExperimentOverview(overview)
    saveUserMetadata()

    registerNewLocalExperiment(withID: experimentID)

    do {
      try upgradeExperimentVersionIfNeeded(experiment)
    } catch {
      // TODO: Handle file version error. http://b/73737685
    }
    saveExperiment(experiment)
  }

  /// Registers a new local experiment with the experiment library and local sync status. This
  /// should be called only for new experiments whose origin is not from Drive.
  ///
  /// - Parameters:
  ///   - experimentID: An experiment ID.
  ///   - isArchived: Whether the experiment is archived.
  func registerNewLocalExperiment(withID experimentID: String, isArchived: Bool = false) {
    // Add to experiment library.
    experimentLibrary.addExperiment(withID: experimentID, isArchived: isArchived)
    saveExperimentLibrary()

    // Add to local sync status as downloaded and dirty.
    localSyncStatus.addExperiment(withID: experimentID)
    localSyncStatus.setExperimentDirty(true, withID: experimentID)
    localSyncStatus.setExperimentDownloaded(true, withID: experimentID)
    saveLocalSyncStatus()
  }

  /// Creates an overview for an experiment with data from the corresponding entry in experiment
  /// library. Only creates the overview if one doesn't already exist.
  ///
  /// - Parameter experiment: An experiment.
  public func createOverviewFromExperimentLibrary(forExperiment experiment: Experiment) {
    // Only create an overview if it doesn't exist.
    let overviewExists =
        userMetadata.experimentOverviews.index(where: { $0.experimentID == experiment.ID }) != nil
    guard let syncExperiment = experimentLibrary.syncExperiment(forID: experiment.ID),
         !overviewExists else {
      return
    }

    let overview = ExperimentOverview(experimentID: experiment.ID)
    overview.colorPalette = MDCPalette.nextExperimentListCardColorPalette(withUsedPalettes:
        experimentOverviews.map { $0.colorPalette })

    overview.isArchived = syncExperiment.isArchived
    overview.lastUsedDate = Date(milliseconds: syncExperiment.lastModifiedTimestamp)
    overview.title = experiment.title
    overview.imagePath = experiment.imagePath

    userMetadata.addExperimentOverview(overview)
    saveUserMetadata()
  }

  /// Creates a default experiment with some welcome content the first time the user launches the
  /// app.
  func createDefaultExperimentIfNecessary() {
    guard !preferenceManager.defaultExperimentWasCreated else { return }
    let (experiment, _) = createExperiment(withTitle: String.firstExperimentTitle)

    // Set chronological timestamps so they display in the correct order.
    let timestamp = Date().millisecondsSince1970

    if let defaultExperimentPicture = UIImage(named: "default_experiment_picture") {
      let picturePath = relativePicturePath(for: "default_experiment_picture")
      saveImage(defaultExperimentPicture, atPicturePath: picturePath, experimentID: experiment.ID)
      let pictureNote = PictureNote()
      pictureNote.timestamp = timestamp
      pictureNote.caption = Caption(text: String.firstExperimentPictureNoteCaption)
      pictureNote.filePath = picturePath
      experiment.notes.append(pictureNote)
      updateCoverImageForAddedImageIfNeeded(imagePath: picturePath, experiment: experiment)
    }

    let textNote = TextNote(text: String.firstExperimentTextNote)
    textNote.timestamp = timestamp + 100
    experiment.notes.append(textNote)

    let linkNote = TextNote(text: String.firstExperimentSecondTextNote)
    linkNote.timestamp = timestamp + 200
    experiment.notes.append(linkNote)

    saveExperiment(experiment)
    preferenceManager.defaultExperimentWasCreated = true
  }

  /// Saves an experiment to disk.
  ///
  /// - Parameters:
  ///   - experiment: An experiment.
  ///   - markDirty: Whether to mark the experiment as dirty. Defaults to true.
  ///   - validateVersion: Whether to validate the experiment version. Defaults to true.
  /// - Returns: True if the save was successful, otherwise false.
  @discardableResult public func saveExperiment(_ experiment: Experiment,
                                                markDirty: Bool = true,
                                                validateVersion: Bool = true) -> Bool {
    do {
      try saveExperiment(experiment,
                         markDirty: markDirty,
                         updateLastModifiedDate: true,
                         validateVersion: validateVersion)
      return true
    } catch let error as MetadataManagerError {
      print("[MetadataManager] Error saving experiment: \(error.logString)")
    } catch {
      print("[MetadataManager]: Error saving experiment: \(error.localizedDescription)")
    }
    return false
  }

  /// Saves an experiment to disk but does not change its last used date. Useful for making saves
  /// to an experiment that are not user-data-related so experiments don't get bumped to the front
  /// of the experiment list.
  ///
  /// - Parameter experiment: An experiment.
  /// - Return: True if the save was successful, otherwise false.
  @discardableResult public func saveExperimentWithoutDateChange(_ experiment: Experiment) -> Bool {
    do {
      try saveExperiment(experiment, markDirty: true, updateLastModifiedDate: false)
      return true
    } catch let error as MetadataManagerError {
      print("[MetadataManager] Error saving experiment: \(error.logString)")
    } catch {
      print("[MetadataManager]: Error saving experiment: \(error.localizedDescription)")
    }
    return false
  }

  /// Saves an experiment to disk at a specific URL. Does not modify the last used date, or update
  /// any overviews. This method should only be used to save experiments outside the user's
  /// experiments directory (such as when importing or exporting an experiment document).
  ///
  /// - Parameters:
  ///   - experiment: An experiment.
  ///   - url: The URL to save the experiment to.
  /// - Return: True if the save was successful, otherwise false.
  @discardableResult func saveExperiment(_ experiment: Experiment, toURL url: URL) -> Bool {
    do {
      try saveExperiment(experiment, markDirty: true, updateLastModifiedDate: false, url: url)
      return true
    } catch let error as MetadataManagerError {
      print("[MetadataManager] Error saving experiment: \(error.logString)")
    } catch {
      print("[MetadataManager]: Error saving experiment: \(error.localizedDescription)")
    }
    return false
  }

  /// Save an experiment to disk, optionally updating its last used date.
  ///
  /// - Parameters:
  ///   - experiment: The experiment.
  ///   - markDirty: Whether to mark the experiment dirty.
  ///   - updateLastModifiedDate: Should the last modified date be updated to now?
  ///   - url: The URL to save the experiment to. If nil it will save it to the current experiments
  ///          directory and update the corresponding overview.
  ///   - validateVersion: Whether to validate the experiment version before saving. Defaults to
  ///                      true.
  /// - Throws: An error if the version is not valid.
  private func saveExperiment(_ experiment: Experiment,
                              markDirty: Bool,
                              updateLastModifiedDate: Bool,
                              url: URL? = nil,
                              validateVersion: Bool = true) throws {
    // The overview's last used date is considered the same as the sync experiment's last modified
    // date.
    updateOverview(for: experiment, updateLastUsedDate: updateLastModifiedDate)

    // If a URL was specified use that, and do not validate version, otherwise save to the
    // experiments directory.
    var experimentURL: URL
    if let url = url {
      experimentURL = url
    } else {
      if validateVersion {
        let fileVersion = experiment.fileVersion

        // This build should not save files with newer versions than it is aware of.
        guard fileVersion.version < Experiment.Version.major ||
            (fileVersion.version == Experiment.Version.major &&
                fileVersion.minorVersion <= Experiment.Version.minor) else {
          throw MetadataManagerError.savingFileWithNewerVersion
        }
      }

      experimentURL = experimentProtoURL(for: experiment.ID)
    }

    if updateLastModifiedDate {
      experimentLibrary.setExperimentModified(withExperimentID: experiment.ID)
      saveExperimentLibrary()
    }

    saveData(experiment.proto.data(), to: experimentURL)

    if markDirty {
      // Mark local sync status as dirty.
      localSyncStatus.setExperimentDirty(true, withID: experiment.ID)
      saveLocalSyncStatus()
    }
  }

  /// Sets an experiment's cover image from image data and metadata. If image data is nil, the cover
  /// image is removed.
  ///
  /// - Parameters:
  ///   - imageData: Image data.
  ///   - metadata: Image metadata.
  ///   - experimentID: The experiment to update.
  func setCoverImageData(_ imageData: Data?,
                         metadata: NSDictionary?,
                         forExperimentID experimentID: String) {
    guard let experiment = experiment(withID: experimentID) else {
      return
    }
    saveCoverImageData(imageData, metadata: metadata, forExperiment: experiment)
    saveExperiment(experiment)
  }

  /// Saves an experiment cover image from image data and metadata. If image data is nil, the cover
  /// image is removed.
  ///
  /// - Parameters:
  ///   - imageData: Image data.
  ///   - metadata: Image metadata.
  ///   - experiment: An experiment.
  func saveCoverImageData(_ imageData: Data?,
                          metadata: NSDictionary?,
                          forExperiment experiment: Experiment) {
    guard let overview = userMetadata.experimentOverview(with: experiment.ID) else {
      return
    }

    let previousCoverImagePath = experiment.imagePath ?? overview.imagePath

    if let imageData = imageData {
      // Generate a unique filename in the assets directory.
      let imagePath = MetadataManager.assetsDirectoryName + "/" + UUID().uuidString + ".jpg"
      saveImageData(imageData,
                    atPicturePath: imagePath,
                    experimentID: experiment.ID,
                    withMetadata: metadata)
      saveCoverImagePath(imagePath, forOverview: overview, experiment: experiment)
    } else {
      saveCoverImagePath(nil, forOverview: overview, experiment: experiment)
    }

    if let previousCoverImagePath = previousCoverImagePath,
        !isImagePathInUseByNotes(previousCoverImagePath, inExperiment: experiment) {
      deleteAssetAtPath(previousCoverImagePath, experimentID: experiment.ID)

      let userInfo = [MetadataManager.deletedCoverImageAssetExperimentIDKey: experiment.ID,
                      MetadataManager.deletedCoverImageAssetFilePathKey: previousCoverImagePath]
      NotificationCenter.default.post(name: .metadataManagerDeletedCoverImageAsset,
                                      object: self,
                                      userInfo: userInfo)
    }
  }

  /// Sets the last used date for an experiment. This does not update experiment library.
  ///
  /// - Parameters:
  ///   - lastUsedDate: The last used date for the experiment.
  ///   - experimentID: An experiment ID.
  ///   - shouldSave: Whether user metadata should be saved after making this change.
  public func setLastUsedDate(_ lastUsedDate: Date,
                              forExperimentWithID experimentID: String,
                              shouldSave: Bool = true) {
    guard let overview = userMetadata.experimentOverview(with: experimentID) else {
      return
    }
    overview.lastUsedDate = lastUsedDate
    if shouldSave {
      saveUserMetadata()
    }
  }

  /// Sets the archived state for an experiment. This does not update experiment library.
  ///
  /// - Parameters:
  ///   - isArchived: Whether the experiment should be set as archived.
  ///   - experimentID: An experiment ID.
  ///   - shouldSave: Whether user metadata should be saved after making this change.
  public func setArchivedState(_ isArchived: Bool,
                               forExperimentWithID experimentID: String,
                               shouldSave: Bool = true) {
    guard let overview = userMetadata.experimentOverview(with: experimentID) else {
      return
    }
    overview.isArchived = isArchived
    if shouldSave {
      saveUserMetadata()
    }
  }

  /// Toggles the archive state of an experiment.
  ///
  /// - Parameter experimentID: An experiment ID.
  /// - Returns: The overview for the archived experiment.
  @discardableResult
      func toggleArchiveStateForExperiment(withID experimentID: String) -> ExperimentOverview? {
    guard let overview = userMetadata.experimentOverview(with: experimentID) else {
      return nil
    }
    overview.isArchived.toggle()
    saveUserMetadata()

    // Update experiment library.
    experimentLibrary.setExperimentArchived(overview.isArchived, experimentID: experimentID)
    saveExperimentLibrary()

    return overview
  }

  /// Is this experiment archived?
  ///
  /// - Parameter experimentID: The experiment ID.
  /// - Returns: The archive state for an experiment.
  func isExperimentArchived(withID experimentID: String) -> Bool {
    guard let overview = userMetadata.experimentOverview(with: experimentID) else { return false }
    return overview.isArchived
  }

  /// Deletes an experiment corresponding to an ID, and removes its associated data and experiment
  /// overview.
  ///
  /// - Parameter experiment ID: An experiment ID.
  /// - Returns: The removed experiment.
  @discardableResult
      func removeExperiment(withID experimentID: String) -> (Experiment, ExperimentOverview)? {
    guard let experiment = experiment(withID: experimentID),
        let overview = removeExperiment(experiment) else {
      return nil
    }
    return (experiment, overview)
  }

  /// Gets the image for an experiment, or returns nil if one is not set.
  ///
  /// - Parameter experiment: The experiment.
  /// - Returns: The image if it exists, nil if not.
  func imageForExperiment(_ experiment: Experiment) -> UIImage? {
    guard let imagePath = imagePathForExperiment(experiment),
        let image = image(forPicturePath: imagePath, experimentID: experiment.ID) else {
      return nil
    }
    return image
  }

  /// Gets the image path for an experiment, or returns nil if one is not set.
  ///
  /// - Parameter experiment: The experiment.
  /// - Returns: The image path if it exists, nil if not.
  func imagePathForExperiment(_ experiment: Experiment) -> String? {
    guard let overview = userMetadata.experimentOverview(with: experiment.ID),
        let imagePath = overview.imagePath else { return nil }
    return imagePath
  }

  /// Upgrades the experiment to the current versions, if necessary.
  /// Saves to disk if an upgrade happened.
  ///
  /// - Parameter experiment: An experiment.
  /// - Throws: A MetadataManagerError if the version is invalid or cannot be upgraded.
  func upgradeExperimentVersionIfNeeded(_ experiment: Experiment) throws {
    try upgradeExperimentVersionIfNeeded(experiment,
                                         toMajorVersion: Experiment.Version.major,
                                         toMinorVersion: Experiment.Version.minor,
                                         toPlatformVersion: Experiment.Version.platform)
  }

  /// Upgrades the experiment to the given versions, if necessary.
  /// Saves to disk if an upgrade happened.
  ///
  /// - Parameters:
  ///   - experiment: An experiment.
  ///   - newMajorVersion: The major version to upgrade to.
  ///   - newMinorVersion: The minor version to upgrade to.
  ///   - newPlatformVersion: The platform version to upgrade to.
  /// - Throws: A MetadataManagerError if the version is invalid or cannot be upgraded.
  func upgradeExperimentVersionIfNeeded(_ experiment: Experiment,
                                        toMajorVersion newMajorVersion: Int32,
                                        toMinorVersion newMinorVersion: Int32,
                                        toPlatformVersion newPlatformVersion: Int32) throws {
    let fileVersion = experiment.fileVersion
    guard fileVersion.version != newMajorVersion ||
        fileVersion.minorVersion != newMinorVersion ||
        fileVersion.platform != .ios ||
        fileVersion.platformVersion != newPlatformVersion else {
      // No upgrade needed.
      return
    }

    guard fileVersion.version <= newMajorVersion else {
      // Too new to read.
      throw MetadataManagerError.openingFileWithNewerVersion(fileVersion.version)
    }

    guard fileVersion.minorVersion <= newMinorVersion else {
      // If the minor version is newer, it does not need an upgrade, but is not considered an error.
      return
    }

    if fileVersion.version == 0 {
      // Upgrade from 0 to 1
      if fileVersion.version < newMajorVersion {
        // There are no migrations from 0 to 1 other than changing the version numbers.
        upgradeExperiment(experiment, toMajorVersion: 1)
      }
    }

    if fileVersion.version == 1 {
      // Minor version upgrades are done within the if statement
      // for their major version counterparts.
      if fileVersion.minorVersion == 0 && fileVersion.minorVersion < newMinorVersion {
        // Upgrade minor version from 0 to 1.
        fileVersion.minorVersion = 1
      }

      if fileVersion.minorVersion == 1 && fileVersion.minorVersion < newMinorVersion {
        // Upgrade minor version from 1 to 2.
        fileVersion.minorVersion = 2
      }

      // More minor version upgrades for major version 1 could be done here.

      // iOS platform version 1 and 2 require migrations.
      if fileVersion.platform != .ios {
        // Update platform version to reflect iOS, if this is coming from Android.
        // Also put any Android version specific fixes in here, if we find any issues.
        experiment.fileVersion.platform = .ios
        experiment.fileVersion.platformVersion = newPlatformVersion
      } else {
        // Migrate total trials for platform version 1.
        if fileVersion.platformVersion == 1 && fileVersion.platformVersion < newPlatformVersion {
          // Update trial indexes for each trial in the experiment
          // Since this has never been set, we don't know about deleted trials, so we will
          // just do our best and index over again.
          experiment.totalTrials = Int32(experiment.trials.count)
          for (index, trial) in experiment.trials.enumerated() {
            trial.trialNumberInExperiment = Int32(index + 1)
          }
        }

        // Migrate image paths, icon paths and trial captions for platform versions 1 and 2.
        if (fileVersion.platformVersion <= 2) &&
            fileVersion.platformVersion < newPlatformVersion {
          // Convert all picture note paths so they are relative to the experiment directory and not
          // the root directory. This matches how Android stores paths and was necessary for cross-
          // platform compatibility.
          var allPictureNotes = experiment.notes.compactMap { $0 as? PictureNote }
          let trialNotes = experiment.trials.flatMap { $0.notes }
          allPictureNotes.append(contentsOf: trialNotes.compactMap { $0 as? PictureNote })
          for pictureNote in allPictureNotes {
            guard var filePath = pictureNote.filePath else {
              continue
            }
            if let assetsRange = filePath.range(of: "/\(MetadataManager.assetsDirectoryName)/") {
              let removeRange = filePath.startIndex...assetsRange.lowerBound
              filePath.removeSubrange(removeRange)
              pictureNote.filePath = filePath
            }
          }

          // Migrate icon paths.
          upgradeExperimentIconPathsForiOSPlatform2(experiment)

          // Migrate trial captions to notes.
          upgradeExperimentTrialCaptionsToNotesForiOSPlatform2(experiment)
        }

        // Add missing stats for zoom tier support in platform version 705 or less.
        if fileVersion.platformVersion <= 705 && fileVersion.platformVersion < newPlatformVersion {
          upgradeExperimentStatsForiOSPlatform705(experiment)
        }

        // Upgrade the platform version if the current one is less than the new one.
        if fileVersion.platformVersion < newPlatformVersion {
          experiment.fileVersion.platform = .ios
          experiment.fileVersion.platformVersion = newPlatformVersion
        }
      }
    }
  }

  /// Adds missing total duration, number of values and zoom tier stats to each trial, which are
  /// required for utilizing zoom tiers. They are missing from iOS platform versions 705 and lower.
  ///
  /// - Parameter experiment: An experiment.
  private func upgradeExperimentStatsForiOSPlatform705(_ experiment: Experiment) {
    for trial in experiment.trials {
      for stats in trial.trialStats {
        if let missingStats =
            sensorDataManager.statsForRecording(withSensorID: stats.sensorID,
                                                trialID: trial.ID) {
          stats.totalDuration = missingStats.lastTimestamp - missingStats.firstTimestamp
          stats.numberOfValues = missingStats.numberOfDataPoints
        }
        if let maxTier =
            sensorDataManager.maxTierForRecording(withSensorID: stats.sensorID,
                                                  trialID: trial.ID) {
          stats.zoomPresenterTierCount = maxTier + 1
          stats.zoomLevelBetweenTiers = Recorder.zoomLevelBetweenTiers
        }
      }
    }
  }

  /// Upgrades an experiment's trial captions to notes for iOS platform version 2. On platform v2
  /// and earlier, trials were able to have captions. The correct spec for Android compatability is
  /// for the trials to not have captions, so they are converted to notes.
  ///
  /// - Parameter experiment: An experiment.
  private func upgradeExperimentTrialCaptionsToNotesForiOSPlatform2(_ experiment: Experiment) {
    experiment.trials.forEach { trial in
      guard let captionText = trial.caption?.text else { return }

      // Create a text note at the timestamp at the start of the trial, with the contents of the
      // caption.
      let textNote = TextNote(text: captionText)
      textNote.timestamp = trial.recordingRange.min
      trial.notes.append(textNote)

      // Remove the caption from the trial.
      trial.caption = nil
    }
  }

  /// Upgrades an experiment's icon paths for iOS platform version 2. On platform v2 and earlier,
  /// icon paths were populated with asset names. The correct spec for Android compatability is
  /// for the icon path to contain the sensor ID.
  ///
  /// - Parameter experiment: An experiment.
  private func upgradeExperimentIconPathsForiOSPlatform2(_ experiment: Experiment) {

    // A map of asset names to sensor IDs.
    let sensorIconMap = [
      "ic_sensor_acc_linear": "LinearAccelerometerSensor",
      "ic_sensor_acc_x": "AccX",
      "ic_sensor_acc_y": "AccY",
      "ic_sensor_acc_z": "AccZ",
      "ic_sensor_audio": "DecibelSource",
      "ic_sensor_barometer": "BarometerSensor",
      "ic_sensor_bluetooth": "",
      "ic_sensor_compass": "CompassSensor",
      "ic_sensor_generic": "",
      "ic_sensor_light": "BrightnessEV",
      "ic_sensor_magnet": "MagneticRotationSensor",
      "ic_sensor_raw": "",
      "ic_sensor_rotation": "",
      "ic_sensor_sound_frequency": "PitchSensor",
    ]

    // Convert icon paths in experiment sensor entries.
    for sensorEntry in experiment.availableSensors {
      if let oldPathString = sensorEntry.sensorSpec.rememberedAppearance.iconPath?.pathString {
        let newPathString = sensorIconMap[oldPathString]
        let newIconPath = IconPath(type: .builtin, pathString: newPathString)
        sensorEntry.sensorSpec.rememberedAppearance.iconPath = newIconPath
        sensorEntry.sensorSpec.rememberedAppearance.largeIconPath = newIconPath
      }
    }

    // Convert icon paths for all snapshot and trigger notes.
    let allNotes = experiment.notes + experiment.trials.flatMap { $0.notes }
    for note in allNotes {
      switch note {
      case let snapshotNote as SnapshotNote:
        for snapshot in snapshotNote.snapshots {
          if let oldPathString = snapshot.sensorSpec.rememberedAppearance.iconPath?.pathString {
            let newPathString = sensorIconMap[oldPathString]
            let newIconPath = IconPath(type: .builtin, pathString: newPathString)
            snapshot.sensorSpec.rememberedAppearance.iconPath = newIconPath
            snapshot.sensorSpec.rememberedAppearance.largeIconPath = newIconPath
          }
        }
      case let triggerNote as TriggerNote:
        if let oldPathString = triggerNote.sensorSpec?.rememberedAppearance.iconPath?.pathString {
          let newPathString = sensorIconMap[oldPathString]
          let newIconPath = IconPath(type: .builtin, pathString: newPathString)
          triggerNote.sensorSpec?.rememberedAppearance.iconPath = newIconPath
          triggerNote.sensorSpec?.rememberedAppearance.largeIconPath = newIconPath
        }
      default: break
      }
    }

    // Convert icon paths for all trial sensor appearances.
    for trial in experiment.trials {
      for case let sensorEntry as GSJTrial_AppearanceEntry in trial.proto.sensorAppearancesArray {
        guard let oldPathString = sensorEntry.rememberedAppearance.iconPath?.pathString else {
          continue
        }
        let newPathString = sensorIconMap[oldPathString]
        let newIconPath = IconPath(type: .builtin, pathString: newPathString)
        sensorEntry.rememberedAppearance.iconPath = newIconPath.proto
      }
    }
  }

  /// Upgrades the experiment to the given major version. Sets minor version to 0 and does not
  /// touch platform version.
  ///
  /// - Parameters:
  ///   - experiment: An experiment.
  ///   - majorVersion: A major version number.
  func upgradeExperiment(_ experiment: Experiment, toMajorVersion majorVersion: Int32) {
    experiment.fileVersion.version = majorVersion
    experiment.fileVersion.minorVersion = 0
  }

  /// Creates a URL for an experiment directory named with the experiment ID.
  ///
  /// - Parameter experimentID: The experiment ID.
  /// - Returns: The URL.
  public func experimentDirectoryURL(for experimentID: String) -> URL {
    return experimentsDirectoryURL.appendingPathComponent(experimentID)
  }

  /// Sets a title for an experiment.
  ///
  /// - Parameters:
  ///   - title: A string title.
  ///   - experimentID: The ID of the experiment to change.
  public func setExperimentTitle(_ title: String?, forID experimentID: String) {
    guard let (experiment, overview) = experimentAndOverview(forExperimentID: experimentID) else {
      return
    }
    experiment.setTitle(title)
    overview.title = title
    saveExperiment(experiment)
    saveUserMetadata()
  }

  /// Whether the image files exist for an experiment.
  ///
  /// - Parameter experiment: An experiment.
  /// - Returns: Whether the image files exist.
  func imageFilesExist(forExperiment experiment: Experiment) -> Bool {
    // A picture note missing its file path is not considered an image file missing.
    var imagePaths = experiment.pictureNotes.compactMap { $0.filePath }
    if let coverImagePath = experiment.imagePath {
      imagePaths.append(coverImagePath)
    }

    for imagePath in imagePaths {
      let filePath = pictureFileURL(for: imagePath, experimentID: experiment.ID).path
      if !FileManager.default.fileExists(atPath: filePath) {
        return false
      }
    }

    return true
  }

  // MARK: - Data removal

  /// When experiments or assets are deleted, they are actually moved to a temporary location to
  /// facilitate easier undo functionality. This method deletes all data from that temporary
  /// location. After this is called, restoring that data is no longer possible.
  func removeAllDeletedData() {
    // Before there was a deleted data directory, there was a deleted assets directory. Delete both.
    [deletedDataDirectoryURL, deletedAssetsDirectoryURL].forEach {
      guard FileManager.default.fileExists(atPath: $0.path) else { return }

      do {
        try FileManager.default.removeItem(at: $0)
      } catch {
        print("[MetadataManager] Error removing deleted data directory: " +
            "\(error.localizedDescription)")
      }
    }
  }

  // Moves the file or directory at `path` to the same relative location in the deleted data
  // directory. `path` must be the location within the Science Journal directory.
  private func moveItemToDeletedData(fromRelativePath path: String) {
    let fromURL = rootURL.appendingPathComponent(path)
    let moveURL = deletedDataDirectoryURL.appendingPathComponent(path)
    var moveDirectoryURL = moveURL.deletingLastPathComponent()

    if FileManager.default.fileExists(atPath: moveDirectoryURL.path, isDirectory:nil) {
      // If the directory already exists, replace the item.
      do {
        _ = try FileManager.default.replaceItemAt(moveURL, withItemAt: fromURL)
      } catch {
        print("[MetadataManager] Error replacing item at '\(moveURL) with item at \(fromURL)': " +
                  "\(error.localizedDescription)")
      }
    } else {
      // Create the directory.
      do {
        try FileManager.default.createDirectory(atPath: moveDirectoryURL.path,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
      } catch {
        print("[MetadataManager] Error creating directory: \(error.localizedDescription)")
        return
      }

      // Deleted data should not be backed up to iCloud.
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      do {
        try moveDirectoryURL.setResourceValues(resourceValues)
      } catch {
        print("[MetadataManager] Error setting resource values on directory " +
          "'\(moveDirectoryURL)': \(error.localizedDescription)")
      }

      // Move the item to deleted data.
      do {
        try FileManager.default.moveItem(at: fromURL, to: moveURL)
      } catch {
        print("[MetadataManager] Error moving item at '\(fromURL)': \(error.localizedDescription)")
      }
    }
  }

  // MARK: Asset removal

  /// Deletes images with the given paths.
  ///
  /// - Parameters:
  ///   - paths: An array of image paths.
  ///   - experiment: An experiment.
  func removeImagesAtPaths(_ imagePaths: [String], experiment: Experiment) {
    for imagePath in imagePaths {
      deleteAssetAtPath(imagePath, experimentID: experiment.ID)
      updateCoverImageForRemovedImageIfNeededWithoutUndo(imagePath: imagePath,
                                                         experiment: experiment)
    }
  }

  /// Moves the asset at the path to the deleted assets directory. This directory is removed on next
  /// launch. This allows for easier undoing of delete actions.
  ///
  /// - Parameters:
  ///   - path: The path relative to the Science Journal directory.
  ///   - experimentID: An experiment ID.
  open func deleteAssetAtPath(_ path: String, experimentID: String) {
    guard let rootPath = URL(string: experimentsDirectoryName)?
        .appendingPathComponent(experimentID)
        .appendingPathComponent(path) else {
      return
    }
    moveItemToDeletedData(fromRelativePath: rootPath.path)
  }

  /// Moves an asset from the deleted assets directory back to the Science Journal directory.
  ///
  /// - Parameters
  ///   - path: The path relative to the Science Journal directory.
  ///   - experimentID: An experimentID.
  func restoreDeletedAssetAtPath(_ path: String, experimentID: String) {
    let restoreURL = pictureFileURL(for: path, experimentID: experimentID)
    let deletedURL = deletedDataDirectoryURL
        .appendingPathComponent(experimentsDirectoryName)
        .appendingPathComponent(experimentID)
        .appendingPathComponent(path)
    do {
      try FileManager.default.moveItem(at: deletedURL, to: restoreURL)
    } catch {
      print("[MetadataManager] Error moving item at '\(deletedURL)': \(error.localizedDescription)")
    }
  }

  // MARK: Experiment removal

  /// Moves an experiment to the deleted experiments directory. This directory is removed on next
  /// launch. This allows for easier undoing of delete actions. The experiment's overview will also
  /// be removed.
  ///
  /// - Parameter experiment: An experiment.
  /// - Returns: The experiment overview associated with the experiment.
  @discardableResult func removeExperiment(_ experiment: Experiment) -> ExperimentOverview? {
    guard let experimentURL =
        URL(string: experimentsDirectoryName)?.appendingPathComponent(experiment.ID) else {
      return nil
    }
    moveItemToDeletedData(fromRelativePath: experimentURL.path)

    // Update overview.
    let experimentOverview = userMetadata.removeExperimentOverview(with: experiment.ID)
    saveUserMetadata()
    return experimentOverview
  }

  /// Moves an experiment from the deleted experiments directory back to the Science Journal
  /// directory. Also adds the experiment overview back into user metadata.
  ///
  /// - Parameter: experimentOverview: The experiment overview.
  func restoreExperiment(forOverview experimentOverview: ExperimentOverview)  {
    guard let experimentURL =
        URL(string: experimentsDirectoryName)?.appendingPathComponent(
            experimentOverview.experimentID) else { return }
    let deletedURL = deletedDataDirectoryURL.appendingPathComponent(experimentURL.path)
    let restoreURL = rootURL.appendingPathComponent(experimentURL.path)
    do {
      try FileManager.default.moveItem(at: deletedURL, to: restoreURL)
      // Add overview.
      userMetadata.addExperimentOverview(experimentOverview)
      saveUserMetadata()
    } catch {
      print("[MetadataManager] Error moving item at '\(deletedURL)': \(error.localizedDescription)")
    }
  }

  /// Permanently removes an experiment without any undo mechanism.
  ///
  /// - Parameter experimentID: An experiment ID.
  /// - Returns: True if an experiment was removed, otherwise false.
  @discardableResult public func permanentlyRemoveExperiment(withID experimentID: String) -> Bool {
    _ = userMetadata.removeExperimentOverview(with: experimentID)
    saveUserMetadata()

    // Update local sync status.
    // This method is called when an experiment is marked as deleted in the experiment library, to
    // confirm it is deleted locally, so it should be removed from local sync status.
    localSyncStatus.removeExperiment(withID: experimentID)
    saveLocalSyncStatus()

    // Don't remove it if it doesn't exist.
    let experimentURL = experimentDirectoryURL(for: experimentID)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: experimentURL.path) else {
      return false
    }

    do {
      try fileManager.removeItem(at: experimentURL)
      return true
    } catch {
      print("[MetadataManager] Error removing item at '\(experimentURL)': " +
          "\(error.localizedDescription)")
      return false
    }
  }

  /// Removes an experiment from deleted data.
  ///
  /// - Parameter experimentID: An experiment ID.
  public func removeExperimentFromDeletedData(withID experimentID: String) {
    guard let experimentURL =
        URL(string: experimentsDirectoryName)?.appendingPathComponent(experimentID) else { return }
    let deletedExperimentURL = deletedDataDirectoryURL.appendingPathComponent(experimentURL.path)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: deletedExperimentURL.path) else { return }
    do {
      try fileManager.removeItem(at: deletedExperimentURL)
    } catch {
      print("[MetadataManager] Error removing experiment from deleted data, with ID: " +
                "\(experimentID). Error: \(error.localizedDescription)")
    }
  }

  // MARK: - Private

  private func experimentProtoURL(for experimentID: String) -> URL {
    return experimentDirectoryURL(for: experimentID)
        .appendingPathComponent(MetadataManager.experimentProtoFilename)
  }

  // Creates the directory if needed, and then saves data. Returns true if the save was successful,
  // otherwise false.
  @discardableResult private func saveData(_ data: Data?, to url: URL) -> Bool {
    guard let data = data else {
      print("[MetadataManager] Data to save is nil when attempting to save to \(url)")
      return false
    }

    // Create the directory, if needed.
    let directoryPath = url.deletingLastPathComponent().path
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: directoryPath, isDirectory:&isDirectory) {
      if !isDirectory.boolValue {
        print("[MetadataManager] Error when creating directory. File already exists, and is not " +
            "a directory at \(url)")
        return false
      }
    } else {
      do {
        try FileManager.default.createDirectory(atPath: directoryPath,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
      } catch {
        print("[MetadataManager] Error creating directory: \(error.localizedDescription)")
        return false
      }
    }

    // Save it.
    do {
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      print("[MetadataManager] Error saving data to \(url): \(error.localizedDescription)")
      return false
    }
  }

  /// Tests an experiment to see if it can be opened based on its version.
  ///
  /// - Parameter experiment: An experiment proto.
  /// - Returns: True if the version of the proto can be opened, otherwise false.
  private func canOpenExperimentVersion(_ experiment: GSJExperiment) -> Bool {
    return experiment.fileVersion.version <= Experiment.Version.major
  }

  /// Sets an image path for an experiment and its overview.
  ///
  /// - Parameters:
  ///   - imagePath: A relative image path to an existing image on disk.
  ///   - overview: An experiment overview to update.
  ///   - experiment: An experiment to update.
  private func saveCoverImagePath(_ imagePath: String?,
                                  forOverview overview: ExperimentOverview,
                                  experiment: Experiment) {
    experiment.imagePath = imagePath
    saveExperiment(experiment)

    overview.imagePath = imagePath
    saveUserMetadata()
  }

  /// Searches an experiment for picture notes and returns the image path for the first one
  /// it finds.
  ///
  /// - Parameter experiment: An experiment.
  /// - Returns: An image path, if one is found.
  private func nextImagePathFromPictureNotes(_ experiment: Experiment) -> String? {
    return experiment.pictureNotes.first?.filePath
  }

  /// Checks an experiment to see if an image path is used by any of its experiment or trial notes.
  ///
  /// - Parameters:
  ///   - imagePath: The image path to check.
  ///   - experiment: An experiment.
  /// - Returns: True if the image path is in use, otherwise false.
  private func isImagePathInUseByNotes(_ imagePath: String,
                                       inExperiment experiment: Experiment) -> Bool {
    let pictureNotePaths = experiment.pictureNotes.compactMap { $0.filePath }
    return pictureNotePaths.contains(imagePath)
  }

  // MARK: - UserMetadata

  // Configures the user metadata object that stores data relevant only to the current user, as well
  // as cached information about experiments for quicker display of experiment lists. This method
  // should only be called once as part of init.
  private func configureUserMetadata() {
    func createNewMetadata() {
      userMetadata = UserMetadata()
      // Set to latest known version.
      userMetadata.fileVersion = FileVersion(major: UserMetadata.Version.major,
                                             minor: UserMetadata.Version.minor,
                                             platform: UserMetadata.Version.platform)
      addMissingOverviewsForExperimentsOnDisk()
    }

    guard let data = try? Data(contentsOf: userMetadataURL) else {
      // If user metadata doesn't exist on disk, create it.
      createNewMetadata()
      return
    }

    guard let proto = try? GSJUserMetadata(data: data) else {
      print("[MetadataManager] Error parsing user metadata proto")
      // If the proto can't be parsed, create a new one.
      createNewMetadata()
      return
    }

    userMetadata = UserMetadata(proto: proto)

    do {
      try upgradeUserMetadataVersionIfNeeded(userMetadata)
      addMissingOverviewsForExperimentsOnDisk()
    } catch {
      let errorString = (error as? MetadataManagerError)?.logString ?? error.localizedDescription
      print("[MetadataManager] Error upgrading user metadata version: " + errorString)
      createNewMetadata()
    }
  }

  /// Scans the experiments directory and adds an overview for any experiment that doesn't have an
  /// overview. This is a guard against any potential bug that accidentally removed an overview
  /// which would prevent the user from accessing their experiment.
  private func addMissingOverviewsForExperimentsOnDisk() {
    let urls = try?
        FileManager.default.contentsOfDirectory(at: experimentsDirectoryURL,
                                                includingPropertiesForKeys: [.nameKey])
    guard let experimentURLs = urls else {
      return
    }

    var didAddAnOverview = false
    for experimentURL in experimentURLs {
      let experimentID = experimentURL.lastPathComponent
      if userMetadata.experimentOverviews.index(where: { $0.experimentID == experimentID }) == nil {
        guard let experiment = experiment(withID: experimentID) else {
          // No valid experiment at this URL, nothing to add.
          continue
        }

        let overview = ExperimentOverview(experimentID: experimentID)
        overview.colorPalette = MDCPalette.nextExperimentListCardColorPalette(withUsedPalettes:
            userMetadata.experimentOverviews.map { $0.colorPalette })
        overview.title = experiment.title
        overview.imagePath = experiment.imagePath

        if let syncExperiment = experimentLibrary.syncExperiment(forID: experimentID) {
          overview.isArchived = syncExperiment.isArchived
          overview.lastUsedDate = Date(milliseconds: syncExperiment.lastModifiedTimestamp)
        } else {
          overview.isArchived = false
          overview.lastUsedDate = clock.now
        }
        userMetadata.addExperimentOverview(overview)
        registerNewLocalExperiment(withID: overview.experimentID, isArchived: overview.isArchived)
        didAddAnOverview = true
      }
    }

    if didAddAnOverview {
      saveUserMetadata()
    }
  }

  /// Saves the current user metadata.
  @discardableResult public func saveUserMetadata() -> Bool {
    return saveUserMetadata(userMetadata)
  }

  /// Saves the given user metadata.
  ///
  /// - Parameter userMetadata: A user metadata instance.
  /// - Returns: True if the save was successful, otherwise false.
  @discardableResult private func saveUserMetadata(_ userMetadata: UserMetadata) -> Bool {
    let fileVersion = userMetadata.fileVersion

    // This build should not save files with newer versions than it is aware of.
    guard fileVersion.version < UserMetadata.Version.major ||
        (fileVersion.version == UserMetadata.Version.major &&
            fileVersion.minorVersion <= UserMetadata.Version.minor) else {
      print("[MetadataManager] Error saving user metadata: " +
          MetadataManagerError.savingFileWithNewerVersion.logString)
      return false
    }

    var success = false
    userMetadataSaveQueue.sync {
      success = saveData(userMetadata.proto.data(), to: userMetadataURL)
    }
    return success
  }

  /// Upgrades the user metadata to the current versions, if needed.
  /// Saves to disk if an upgrade happened.
  ///
  /// - Parameter userMetadata: A user metadata instance.
  /// - Throws: A MetadataManagerError if version is invalid or cannot be upgraded.
  func upgradeUserMetadataVersionIfNeeded(_ userMetadata: UserMetadata) throws {
    try upgradeUserMetadataVersionIfNeeded(userMetadata,
                                           toMajorVersion: UserMetadata.Version.major,
                                           toMinorVersion: UserMetadata.Version.minor,
                                           toPlatformVersion: UserMetadata.Version.platform)
  }

  /// Upgrades the user metadata to the given versions, if needed.
  /// Saves to disk if an upgrade happened.
  ///
  /// - Parameters:
  ///   - userMetadata: A user metadata instance.
  ///   - newMajorVersion: The major version to upgrade to.
  ///   - newMinorVersion: The minor version to upgrade to.
  ///   - newPlatformVersion: The platform version to upgrade to.
  /// - Throws: A MetadataManagerError if version is invalid or cannot be upgraded.
  func upgradeUserMetadataVersionIfNeeded(_ userMetadata: UserMetadata,
                                          toMajorVersion newMajorVersion: Int32,
                                          toMinorVersion newMinorVersion: Int32,
                                          toPlatformVersion newPlatformVersion: Int32) throws {
    let fileVersion = userMetadata.fileVersion
    guard fileVersion.version != newMajorVersion ||
      fileVersion.minorVersion != newMinorVersion ||
      fileVersion.platformVersion != newPlatformVersion else {
        // No upgrade needed.
        return
    }

    // Major version must be less than or equal to latest known version in order to read it.
    guard fileVersion.version <= newMajorVersion else {
      // Too new to read.
      throw MetadataManagerError.openingFileWithNewerVersion(fileVersion.version)
    }

    // Migrate from major version 0 -> 1
    if fileVersion.version == 0 {
      // Upgrade from 0 to 1
      if fileVersion.version < newMajorVersion {
        // There are no migrations from 0 to 1 other than changing the version numbers.
        fileVersion.version = 1
        fileVersion.minorVersion = 0
      }
    }

    // Migrate from major version 1.X to latest, if necessary.
    if fileVersion.version == 1 {
      // Minor version upgrades are done within the if statement
      // for their major version counterparts.
      if fileVersion.minorVersion == 0 && fileVersion.minorVersion < newMinorVersion {
        fileVersion.minorVersion = 1
      }

      // More minor version upgrades for major version 1 could be done here.

      // Upgrade image paths for platform versions <= 1.
      if fileVersion.platform == .ios {
        if fileVersion.platformVersion <= 1 && fileVersion.platformVersion < newPlatformVersion {
          for overview in userMetadata.experimentOverviews {
            guard var imagePath = overview.imagePath else {
              continue
            }
            if let assetsRange = imagePath.range(of: "/\(MetadataManager.assetsDirectoryName)/") {
              let removeRange = imagePath.startIndex...assetsRange.lowerBound
              imagePath.removeSubrange(removeRange)
              overview.imagePath = imagePath
            }
          }
        }

        if fileVersion.platformVersion <= 705 && fileVersion.platformVersion < newPlatformVersion {
          for overview in userMetadata.experimentOverviews {
            guard overview.imagePath == nil,
                let experiment = experiment(withID: overview.experimentID) else {
              continue
            }
            overview.imagePath = nextImagePathFromPictureNotes(experiment)
          }
        }
      }
    }

    fileVersion.version = newMajorVersion
    fileVersion.minorVersion = newMinorVersion
    fileVersion.platform = .ios
    fileVersion.platformVersion = newPlatformVersion

    saveUserMetadata(userMetadata)
  }

  // MARK: - Experiment Library

  /// The experiment library. It tracks the state of experiments for Drive sync.
  public lazy var experimentLibrary: ExperimentLibrary = {
    func createExperimentLibrary() -> ExperimentLibrary {
      let experimentLibrary =
          ExperimentLibrary(localExperimentOverviews: self.experimentOverviews,
                            clock: clock)
      experimentLibrarySaveQueue.sync {
        _ = self.saveData(experimentLibrary.proto.data(), to: self.experimentLibraryURL)
      }
      return experimentLibrary
    }

    guard let data = try? Data(contentsOf: self.experimentLibraryURL) else {
      // If the experiment library doesn't exist on disk, create it.
      return createExperimentLibrary()
    }

    guard let proto = try? GSJExperimentLibrary(data: data) else {
      print("[MetadataManager] Error parsing experiment library proto")
      // If the proto can't be parsed, create a new one.
      return createExperimentLibrary()
    }

    return ExperimentLibrary(proto: proto, clock: clock)
  }()

  /// Saves the current experiment library.
  @discardableResult public func saveExperimentLibrary() -> Bool {
    var saveSucceeded = false
    experimentLibrarySaveQueue.sync {
      saveSucceeded = saveData(experimentLibrary.proto.data(), to: experimentLibraryURL)
    }
    return saveSucceeded
  }

  /// Marks an experiment as opened in the experiment library. Should be called whenever a user
  /// opens an experiment.
  ///
  /// - Parameter experimentID: An experiment ID.
  func markExperimentOpened(withID experimentID: String) {
    experimentLibrary.setExperimentOpened(withExperimentID: experimentID)
  }

  // MARK: - Local Sync Status

  /// The local sync status. It tracks the Drive sync state of local experiments.
  public lazy var localSyncStatus: LocalSyncStatus = {
    func createLocalSyncStatus() -> LocalSyncStatus {
      let localSyncStatus = LocalSyncStatus()
      localSyncStatusSaveQueue.sync{
        _ = self.saveData(localSyncStatus.proto.data(), to: self.localSyncStatusURL)
      }
      return localSyncStatus
    }

    guard let data = try? Data(contentsOf: self.localSyncStatusURL) else {
      return createLocalSyncStatus()
    }

    guard let proto = try? GSJLocalSyncStatus(data: data) else {
      print("[MetadataManager] Error parsing local sync status")
      return createLocalSyncStatus()
    }

    return LocalSyncStatus(proto: proto)
  }()

  /// Saves the local sync status to disk.
  ///
  /// - Returns: True if the save succeeded, otherwise false.
  @discardableResult public func saveLocalSyncStatus() -> Bool {
    var saveSucceeded = false
    localSyncStatusSaveQueue.sync {
      saveSucceeded = saveData(localSyncStatus.proto.data(), to: localSyncStatusURL)
    }
    return saveSucceeded
  }

  // MARK: - Pictures

  /// Generates and returns the file path relative to an experiment directory, including jpg
  /// extension, for a picture in an experiment or trial.
  ///
  /// - Parameter pictureNoteID: The picture note ID.
  /// - Returns: A file path.
  func relativePicturePath(for pictureNoteID: String) -> String {
    return URL(fileURLWithPath: MetadataManager.assetsDirectoryName)
        .appendingPathComponent(pictureNoteID).appendingPathExtension("jpg").path
  }

  /// Saves an image at a path.
  ///
  /// - Parameters:
  ///   - image: The image.
  ///   - picturePath: The path.
  ///   - experimentID: An experimentID.
  func saveImage(_ image: UIImage, atPicturePath picturePath: String, experimentID: String) {
    guard let imageData = image.jpegData(compressionQuality: 0.8) else {
      print("[MetadataManager] Error when creating image data.")
      return
    }

    saveData(imageData, to: pictureFileURL(for: picturePath, experimentID: experimentID))
  }

  /// Saves image data and its metadata at a path and returns the combined image.
  ///
  /// - Parameters:
  ///   - imageData: The image data.
  ///   - picturePath: The path.
  ///   - experimentID: An experimentID.
  ///   - metadata: The metadata to apply to the image.
  /// - Returns: The saved image, with metadata applied.
  @discardableResult func saveImageData(_ imageData: Data,
                                        atPicturePath picturePath: String,
                                        experimentID: String,
                                        withMetadata metadata: NSDictionary?) -> UIImage? {
    // Grab the image as data, create a CGImageSource for it.
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
        let uniformTypeID = CGImageSourceGetType(source) else { return nil }

    // Change the CFData to mutable data we can change after adding exif.
    let combinedData = NSMutableData(data: imageData)
    // Create a CGImage destination out of the mutable data, which we'll write to with exif.
    guard let destination =
      CGImageDestinationCreateWithData(combinedData as CFMutableData, kUTTypeJPEG, 1, nil) else {
        return nil
    }

    // Add the image and metadata to the destination.
    CGImageDestinationAddImageFromSource(destination, source, 0, metadata)
    var options: CFDictionary?
    if !CFEqual(uniformTypeID, kUTTypeJPEG) {
      // Set a compression value if the image wasn't a JPG.
      options = [
        kCGImageDestinationLossyCompressionQuality as String: NSNumber(value: 0.8)
      ] as CFDictionary
    }
    CGImageDestinationSetProperties(destination, options)
    // Write the image data + exif to the mutable data destination. In this case, we're really just
    // combining the exif with the existing data.
    CGImageDestinationFinalize(destination)

    // Create a compressed image out of the data to pass back to the controller who needs to
    // display it.
    guard let completedImage = UIImage(data: combinedData as Data) else { return nil }

    // Save the combined, compressed image data to disk.
    saveData(combinedData as Data, to: pictureFileURL(for: picturePath, experimentID: experimentID))

    return completedImage
  }

  /// Returns the image at a relative picture path.
  ///
  /// - Parameters:
  ///   - picturePath: The path relative to an experiment directory.
  ///   - experimentID: An experimentID.
  /// - Returns: An image.
  func image(forPicturePath picturePath: String, experimentID: String) -> UIImage? {
    let fullPath = pictureFileURL(for: picturePath,
                                  experimentID: experimentID).path
    return image(forFullImagePath: fullPath)
  }

  /// Returns the image at the full image path.
  ///
  /// - Parameter fullImagePath: A full image path.
  /// - Returns: An image.
  func image(forFullImagePath fullImagePath: String) -> UIImage? {
    return UIImage(contentsOfFile: fullImagePath)
  }

  /// Returns the exif data for the image at a path, if it exists.
  ///
  /// - Parameter imagePath: The path of an image.
  /// - Returns: The exif dictionary, if available. Nil if not.
  func exifDataForImagePath(_ imagePath: String) -> ExifData? {
    return ExifData(atURL: URL(fileURLWithPath: imagePath))
  }

  /// The full URL for a relative picture path.
  ///
  /// - Parameters:
  ///   - path: A path relative to an experiment.
  ///   - experimentID: An experiment ID.
  /// - Returns: A full URL for the relative picture path.
  public func pictureFileURL(for path: String, experimentID: String) -> URL {
    return experimentsDirectoryURL.appendingPathComponent(experimentID).appendingPathComponent(path)
  }

  // MARK: - Recording Protos

  /// Returns a recording proto URL for a specific trial.
  ///
  /// - Parameters:
  ///   - trialID: A trial ID.
  ///   - experimentID: The ID of the experiment that owns the trial.
  /// - Returns: A recording proto URL.
  public func recordingURL(forTrialID trialID: String, experimentID: String) -> URL {
    let filename = "recording_\(trialID).proto"
    let experimentURL = experimentDirectoryURL(for: experimentID)
    return experimentURL.appendingPathComponent(filename)
  }

  // MARK: - Sensor Icons

  /// Returns the image at a sensor icon path.
  ///
  /// - Parameter sensorIconPath: The path.
  /// - Returns: The image.
  func image(forSensorIconPath sensorIconPath: String) -> UIImage? {
    return UIImage(named: sensorIconPath)
  }

  // MARK: - Bluetooth sensors

  /// Reads the users stored bluetooth sensors and adds them to the sensor controller so they can
  /// be used when observing. Should be called when a user opens the app or logs in.
  func registerBluetoothSensors() {
    // Load any existing bluetooth specs from disk and create sensors.
    for spec in bluetoothSensorSpecs {
      let interface = MakingScienceSensorInterface(name: spec.rememberedAppearance.name,
                                                   identifier: spec.gadgetInfo.address)
      if let sensorConfig = try? GSJBleSensorConfig(data: spec.config) {
        interface.sensorConfig = sensorConfig
      }

      let sensor = BluetoothSensor(sensorInterface: interface,
                                   sensorTimer: sensorController.unifiedSensorTimer)
      sensorController.addOrUpdateBluetoothSensor(sensor)
    }
  }

  /// Removes the users bluetooth sensors from the sensor controller so they are no longer available
  /// when observing. Should be called when a user logs out.
  func unregisterBluetoothSensors() {
    sensorController.removeAllBluetoothSensors()
  }

  /// Saves a bluetooth sensor and updates it with the sensor controller.
  ///
  /// - Parameter sensorInterface: A sensor interface.
  /// - Returns: A bluetooth sensor.
  @discardableResult func saveAndUpdateBluetoothSensor(
      _ sensorInterface: BLESensorInterface) -> BluetoothSensor {
    let sensorSpec = SensorSpec(bleSensorInterface: sensorInterface)
    saveBluetoothSensor(sensorSpec)
    let bluetoothSensor = BluetoothSensor(sensorInterface: sensorInterface,
                                          sensorTimer: sensorController.unifiedSensorTimer)
    sensorController.addOrUpdateBluetoothSensor(bluetoothSensor)
    return bluetoothSensor
  }

  /// Deletes a bluetooth sensor and removes it from the sensor controller.
  ///
  /// - Parameter bluetoothSensor: A bluetooth sensor.
  func removeBluetoothSensor(_ bluetoothSensor: BluetoothSensor) {
    let providerID = bluetoothSensor.sensorInterafce.providerId
    deleteBluetoothSensor(withID: bluetoothSensor.sensorId, providerID: providerID)
    sensorController.removeBluetoothSensor(bluetoothSensor)
  }

  /// Saves a bluetooth sensor spec to disk.
  ///
  /// - Parameter sensorSpec: A sensor spec.
  func saveBluetoothSensor(_ sensorSpec: SensorSpec) {
    guard let data = sensorSpec.proto.data() else {
      print("[MetadataManager] Error extracting data from sensor spec.")
      return
    }

    let url = bluetoothSensorSpecURL(forProviderID: sensorSpec.gadgetInfo.providerID,
                                     address: sensorSpec.gadgetInfo.address)
    saveData(data, to: url)
  }

  /// Deletes all bluetooth sensors from disk.
  func deleteAllBluetoothSensors() {
    unregisterBluetoothSensors()
    for spec in bluetoothSensorSpecs {
      deleteBluetoothSensor(withID: spec.gadgetInfo.address, providerID: spec.gadgetInfo.providerID)
    }
  }

  /// Deletes a bluetooth sensor spec from disk.
  ///
  /// - Parameter sensorSpec: The spec describing the sensor to delete.
  func deleteBluetoothSensor(withID identifier: String, providerID: String) {
    let url = bluetoothSensorSpecURL(forProviderID: providerID, address: identifier)
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      print("[MetadataManager] Error removing bluetooth sensor spec: \(error.localizedDescription)")
    }
  }

  private func bluetoothSensorSpecURL(forProviderID providerID: String, address: String) -> URL {
    // Name the saved proto by concatenating the provider id with the address.
    let filename = providerID + address
    return bluetoothSensorsDirectoryURL.appendingPathComponent(filename)
  }

  /// Returns all bluetooth sensors specs found on disk.
  var bluetoothSensorSpecs: [SensorSpec] {
    guard let fileURLs =
        try? FileManager.default.contentsOfDirectory(at: bluetoothSensorsDirectoryURL,
                                                     includingPropertiesForKeys: nil) else {
      return []
    }

    var sensorSpecs = [SensorSpec]()
    for url in fileURLs {
      if let data = try? Data(contentsOf: url), let proto = try? GSJSensorSpec(data: data) {
        sensorSpecs.append(SensorSpec(proto: proto))
      }
    }
    return sensorSpecs
  }

}
