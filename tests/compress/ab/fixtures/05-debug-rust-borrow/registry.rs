use std::collections::HashMap;

pub struct Watcher {
    pub id: u64,
    pub alive: bool,
}

pub struct Registry {
    watchers: HashMap<u64, Watcher>,
}

impl Registry {
    pub fn notify_and_prune(&mut self, event: &str) {
        for (id, watcher) in &self.watchers {
            if watcher.alive {
                self.deliver(*id, event);
            } else {
                self.watchers.remove(id);
            }
        }
    }

    fn deliver(&mut self, id: u64, event: &str) {
        if let Some(w) = self.watchers.get_mut(&id) {
            w.alive = event != "shutdown";
        }
    }
}
