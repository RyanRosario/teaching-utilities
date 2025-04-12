directory = 'YOUR_FOLDER_ID'

function removeSharingFromFolder(folderId) {
  const folder = DriveApp.getFolderById(folderId);
  console.log(`Starting sharing removal in folder: ${folder.getName()}`);
  removeSharingRecursively(folder);
  console.log("Sharing removal completed.");
}

function removeSharingRecursively(folder) {
  // Remove sharing from files in the current folder in batches
  const files = folder.getFiles();
  let fileCount = 0;
  while (files.hasNext()) {
    const file = files.next();
      if (file.getMimeType() === "application/pdf" || file.getMimeType() === "application/tex") {
      try {
        removeAllPermissions(file);
        fileCount++;
        console.log(`Permissions removed for file: ${file.getName()} (${fileCount})`);
      } catch (e) {
        console.error(`Failed to remove permissions for file: ${file.getName()}. Error: ${e}`);
      }
      // Prevent timeout by stopping after every 50 files
      if (fileCount >= 50) {
        console.log("Pausing for a moment to prevent timeout.");
        Utilities.sleep(1000); // Wait 1 second before resuming
        fileCount = 0;
      }
    }
  }

  // Process each subfolder recursively
  const subfolders = folder.getFolders();
  while (subfolders.hasNext()) {
    const subfolder = subfolders.next();
    removeSharingRecursively(subfolder);
  }
}

function removeAllPermissions(file) {
  // Remove all editor and viewer permissions
  const editors = file.getEditors();
  const viewers = file.getViewers();
  
  editors.forEach(editor => {
    try {
      file.removeEditor(editor);
      console.log(`Removed editor: ${editor.getEmail()}`);
    } catch (e) {
      console.error(`Failed to remove editor: ${editor.getEmail()}. Error: ${e}`);
    }
  });
  
  viewers.forEach(viewer => {
    try {
      file.removeViewer(viewer);
      console.log(`Removed viewer: ${viewer.getEmail()}`);
    } catch (e) {
      console.error(`Failed to remove viewer: ${viewer.getEmail()}. Error: ${e}`);
    }
  });
}
// To run the script:
// 1. Replace 'YOUR_FOLDER_ID' at the top with the actual ID of your root folder.
// 2. In the Script Editor, click the 'Run' button and select the function.
function main() {
  var rootFolderId = directory;  // enter folder ID here.
  removeSharingFromFolder(rootFolderId);
  console.log('Process complete.');
}
