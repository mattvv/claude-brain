This fails to compile with:

error[E0502]: cannot borrow `self.watchers` as mutable because it is also
borrowed as immutable
  --> src/registry.rs:18:13

Explain the root cause and give the minimal fix that keeps the notify-then-prune
behavior.
