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

import Foundation

@testable import third_party_sciencejournal_ios_ScienceJournalOpen

// A simple operation whose execution can be verified.
class SimpleOperation: GSJOperation {
  var taskComplete = false
  var finishErrors = [Error]()
  override func execute() {
    taskComplete = true
    finish()
  }

  override func finished(withErrors errors: [Error]) {
    finishErrors.append(contentsOf: errors)
  }
}
