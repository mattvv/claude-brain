# claude-brain consultant visibility

Consultations should be visible while they run. In order of preference:

1. INLINE (default): when you have — or can quickly gather — the context yourself,
   call `brain-ask <model> --effort <E> --stream -` directly from the main session.
   The consultant's answer then streams into the main chat as it generates.
2. Foreground bridge agent (`brain-*` with `run_in_background: false`): when context
   gathering is heavy enough to be worth doing off-thread. Its activity renders under
   a collapsible task group, so tell the user that's where to watch.

Background a consultant only when the user asks for that, or when you have genuinely
parallel work to do while it runs — and say so when you do.

(The user can flip this default with: `brain config consult background`.)
