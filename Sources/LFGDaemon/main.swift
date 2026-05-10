import Foundation

// LFG Daemon — XPC service entry point
// Implements FSEventsStream watcher for /Volumes
// Handles YJ_MORE connect/disconnect → auto-attach sparseimages

RunLoop.main.run()
