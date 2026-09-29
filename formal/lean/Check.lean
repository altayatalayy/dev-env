import DevEnv

-- No theorem below may depend on anything beyond Lean's three standard axioms
-- (propext, Classical.choice, Quot.sound). In particular: no `sorryAx`, and no
-- `Lean.ofReduceBool` from `native_decide`.
#print axioms DevEnv.Managed.underRoot_sound
#print axioms DevEnv.Managed.underRoot_child
#print axioms DevEnv.Managed.underRoot_sibling_rejected
#print axioms DevEnv.Managed.underRoot_shorter_rejected
#print axioms DevEnv.Managed.no_sibling_is_ever_managed
#print axioms DevEnv.Ids.mem_missingFrom
#print axioms DevEnv.Ids.mem_sortedUnique
#print axioms DevEnv.Ids.nodup_sortedUnique
#print axioms DevEnv.Diff.install_remove_disjoint
#print axioms DevEnv.Diff.appliedTools_eq_desired
#print axioms DevEnv.Diff.diff_after_apply_isEmpty
#print axioms DevEnv.Diff.isEmpty_iff_agree
#print axioms DevEnv.Resolve.closed_of_fixpoint
#print axioms DevEnv.Resolve.fixpoint_of_closed
#print axioms DevEnv.Resolve.length_lt_of_not_fixpoint
