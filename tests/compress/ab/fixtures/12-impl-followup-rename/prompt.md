We renamed Settings.load_from to Settings.from_path (diff below), but CI now
fails in modules the diff never touched. List what else must change for this
rename to be complete, including anything the diff missed inside the same file.
