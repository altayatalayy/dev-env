/-!
# Name-list helpers

Models `src/shared/ids.zig`, the set operations every plan and diff is built
from. Tool and config names cross the process boundary as plain strings, so
these three functions are the only "set" implementation in the system.

`sortedUnique` is the interesting one: it sorts with `std.mem.sort` and then
compacts in place by comparing each element against the *last kept* one. We
verify the compaction (our code) against a specification of the sort (the
standard library's contract), which is stated as hypotheses rather than assumed
silently.
-/

namespace DevEnv.Ids

variable {α : Type} [BEq α] [LawfulBEq α]

/-- `ids.missingFrom`: every name in `from` that is not in `in`. -/
def missingFrom (fromL inL : List α) : List α :=
  fromL.filter (fun n => !inL.contains n)

/--
The compaction half of `ids.sortedUnique`:

```zig
var len: usize = 0;
for (copy) |name| {
    if (len > 0 and eql(copy[len - 1], name)) continue;
    copy[len] = name;
    len += 1;
}
```

`last` is `copy[len - 1]`, i.e. the most recently kept element (`none` while
nothing has been kept yet).
-/
def compact (last : Option α) : List α → List α
  | [] => []
  | a :: t =>
    match last with
    | none => a :: compact (some a) t
    | some p => if p == a then compact (some p) t else a :: compact (some a) t

/-- `ids.sortedUnique` with the sort supplied by the caller. -/
def sortedUnique (sort : List α → List α) (l : List α) : List α :=
  compact none (sort l)

/-! ## `missingFrom` is set difference -/

theorem mem_missingFrom {x : α} {a b : List α} :
    x ∈ missingFrom a b ↔ x ∈ a ∧ x ∉ b := by
  simp [missingFrom, List.mem_filter]

/-- `plan` prints "nothing to change" exactly when nothing is missing. -/
theorem missingFrom_eq_nil_iff {a b : List α} :
    missingFrom a b = [] ↔ ∀ x ∈ a, x ∈ b := by
  simp [missingFrom, List.filter_eq_nil_iff]

/-! ## `compact` preserves membership -/

omit [LawfulBEq α] in
theorem mem_compact_of_mem_tail {x : α} {last : Option α} {l : List α}
    (h : x ∈ compact last l) : x ∈ l := by
  induction l generalizing last with
  | nil => simp [compact] at h
  | cons a t ih =>
    cases last with
    | none =>
      simp only [compact] at h
      rcases List.mem_cons.1 h with rfl | h'
      · exact List.mem_cons_self ..
      · exact List.mem_cons_of_mem _ (ih h')
    | some p =>
      simp only [compact] at h
      split at h
      · exact List.mem_cons_of_mem _ (ih h)
      · rcases List.mem_cons.1 h with rfl | h'
        · exact List.mem_cons_self ..
        · exact List.mem_cons_of_mem _ (ih h')

/-- Nothing is dropped except a repeat of the element just kept. -/
theorem mem_compact_some {x p : α} {l : List α} (h : x ∈ l) :
    x = p ∨ x ∈ compact (some p) l := by
  induction l generalizing p with
  | nil => simp at h
  | cons a t ih =>
    simp only [compact]
    split
    · next hpa =>
      have hpa' : p = a := by simpa using hpa
      rcases List.mem_cons.1 h with rfl | h'
      · exact Or.inl hpa'.symm
      · exact ih h'
    · rcases List.mem_cons.1 h with rfl | h'
      · exact Or.inr (List.mem_cons_self ..)
      · rcases ih (p := a) h' with rfl | hmem
        · exact Or.inr (List.mem_cons_self ..)
        · exact Or.inr (List.mem_cons_of_mem _ hmem)

theorem mem_compact_none {x : α} {l : List α} : x ∈ compact none l ↔ x ∈ l := by
  constructor
  · exact mem_compact_of_mem_tail
  · intro h
    cases l with
    | nil => simp at h
    | cons a t =>
      simp only [compact]
      rcases List.mem_cons.1 h with rfl | h'
      · exact List.mem_cons_self ..
      · rcases mem_compact_some (p := a) h' with rfl | hmem
        · exact List.mem_cons_self ..
        · exact List.mem_cons_of_mem _ hmem

/--
`sortedUnique` loses nothing and invents nothing, given only that the sort
permutes its input (the part of `std.mem.sort`'s contract we depend on here).
-/
theorem mem_sortedUnique {sort : List α → List α} {l : List α} {x : α}
    (hsort : ∀ y, y ∈ sort l ↔ y ∈ l) :
    x ∈ sortedUnique sort l ↔ x ∈ l := by
  rw [sortedUnique, mem_compact_none, hsort]

/-! ## `compact` removes duplicates from a sorted list

The sort contract we rely on: the result is pairwise `le` for an order that is
antisymmetric. That is exactly enough to make equal elements adjacent, which is
what the in-place compaction assumes.
-/

variable (le : α → α → Prop)

/-- Invariant of the loop: `p` is the last kept element, and it is `≤`
everything still to come. -/
theorem compact_spec (antisymm : ∀ a b, le a b → le b a → a = b) :
    ∀ (l : List α) (_ : l.Pairwise le) (p : α) (_ : ∀ x ∈ l, le p x),
      (compact (some p) l).Nodup ∧ p ∉ compact (some p) l := by
  intro l
  induction l with
  | nil => intro _ p _; simp [compact]
  | cons a t ih =>
    intro hpair p hp
    have hat : ∀ x ∈ t, le a x := (List.pairwise_cons.1 hpair).1
    have htail : t.Pairwise le := (List.pairwise_cons.1 hpair).2
    simp only [compact]
    split
    · next hpa =>
      have hpa' : p = a := by simpa using hpa
      subst hpa'
      exact ih htail p (fun x hx => hp x (List.mem_cons_of_mem _ hx))
    · next hpa =>
      have hne : p ≠ a := by simpa using hpa
      obtain ⟨hnodup, hnotmem⟩ := ih htail a hat
      refine ⟨List.nodup_cons.2 ⟨hnotmem, hnodup⟩, ?_⟩
      intro hmem
      rcases List.mem_cons.1 hmem with rfl | hmem'
      · exact hne rfl
      · have hpt : p ∈ t := mem_compact_of_mem_tail hmem'
        exact hne (antisymm p a (hp a (List.mem_cons_self ..)) (hat p hpt))

/-- The compacted list of a sorted list has no duplicates. -/
theorem nodup_compact_none (antisymm : ∀ a b, le a b → le b a → a = b)
    {l : List α} (hpair : l.Pairwise le) : (compact none l).Nodup := by
  cases l with
  | nil => simp [compact]
  | cons a t =>
    have hat : ∀ x ∈ t, le a x := (List.pairwise_cons.1 hpair).1
    have htail : t.Pairwise le := (List.pairwise_cons.1 hpair).2
    obtain ⟨hnodup, hnotmem⟩ := compact_spec le antisymm t htail a hat
    simpa [compact] using List.nodup_cons.2 ⟨hnotmem, hnodup⟩

/--
`sortedUnique` is duplicate-free. Combined with `mem_sortedUnique`, that is the
full "it is a set" property the diff and the `owned_symlinks` / `owned_prefixes`
bookkeeping depend on.
-/
theorem nodup_sortedUnique {sort : List α → List α} {l : List α}
    (antisymm : ∀ a b, le a b → le b a → a = b)
    (hpair : (sort l).Pairwise le) :
    (sortedUnique sort l).Nodup :=
  nodup_compact_none le antisymm hpair

end DevEnv.Ids
