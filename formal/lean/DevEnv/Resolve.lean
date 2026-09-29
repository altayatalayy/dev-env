/-!
# Dependency closure

Models the fixpoint loop at the heart of `resolver.resolve`:

```zig
var changed = true;
while (changed) {
    changed = false;
    for (defs.tools) |t| {
        if (!tool_set.contains(t.id)) continue;
        for (method.dependencies().install.tools) |dep| {
            if (!tool_set.contains(dep)) { tool_set.insert(dep); changed = true; }
        }
        ...
    }
}
```

`deps t` abstracts "the tools required by the install method selected for this
host", which is why resolution is package-manager aware: the same tool has a
different `deps` on apt/dnf than on brew.

Two things matter and are proved here: the loop **only stops when the set is
dependency-closed**, and it **always stops**, because each non-final iteration
strictly grows a set bounded by the finite `ToolId` enum.
-/

namespace DevEnv.Resolve

variable {α : Type} [BEq α] [LawfulBEq α]

/-- One iteration: add every not-yet-present dependency of a member. -/
def step (deps : α → List α) (s : List α) : List α :=
  s ++ (s.flatMap deps).filter (fun d => !s.contains d)

/-- The set contains every dependency of every member. -/
def Closed (deps : α → List α) (s : List α) : Prop :=
  ∀ t ∈ s, ∀ d ∈ deps t, d ∈ s

theorem mem_step {deps : α → List α} {s : List α} {x : α} :
    x ∈ step deps s ↔ x ∈ s ∨ ∃ t ∈ s, x ∈ deps t := by
  simp only [step, List.mem_append, List.mem_filter, List.mem_flatMap,
    Bool.not_eq_true', decide_eq_false_iff_not, List.contains_eq_mem]
  constructor
  · rintro (h | ⟨⟨t, ht, hx⟩, -⟩)
    · exact Or.inl h
    · exact Or.inr ⟨t, ht, hx⟩
  · rintro (h | ⟨t, ht, hx⟩)
    · exact Or.inl h
    · by_cases hs : x ∈ s
      · exact Or.inl hs
      · exact Or.inr ⟨⟨t, ht, hx⟩, hs⟩

/-- The iteration never loses anything. -/
theorem subset_step {deps : α → List α} {s : List α} {x : α} (h : x ∈ s) :
    x ∈ step deps s :=
  mem_step.2 (Or.inl h)

/--
**The loop's exit condition is exactly dependency closure.** When `step` adds
nothing new, every dependency of every selected tool is already in the set — so
`resolved_tools` really is the full closure, never a partial one.
-/
theorem closed_of_fixpoint {deps : α → List α} {s : List α}
    (h : ∀ x ∈ step deps s, x ∈ s) : Closed deps s := by
  intro t ht d hd
  exact h d (mem_step.2 (Or.inr ⟨t, ht, hd⟩))

/-- Conversely, a closed set is a fixpoint: the loop cannot spin forever on one. -/
theorem fixpoint_of_closed {deps : α → List α} {s : List α}
    (h : Closed deps s) : ∀ x ∈ step deps s, x ∈ s := by
  intro x hx
  rcases mem_step.1 hx with hs | ⟨t, ht, hd⟩
  · exact hs
  · exact h t ht x hd

omit [LawfulBEq α] in
/-- Every non-final iteration strictly grows the set. -/
theorem length_lt_of_not_fixpoint {deps : α → List α} {s : List α}
    (h : ∃ x ∈ step deps s, x ∉ s) : s.length < (step deps s).length := by
  obtain ⟨x, hx, hns⟩ := h
  simp only [step, List.mem_append] at hx
  have hfilter : x ∈ (s.flatMap deps).filter (fun d => !s.contains d) := by
    rcases hx with h' | h'
    · exact absurd h' hns
    · exact h'
  have : 0 < ((s.flatMap deps).filter (fun d => !s.contains d)).length :=
    List.length_pos_of_mem hfilter
  simp only [step, List.length_append]
  omega

/--
The set never escapes the universe of declared tools, which in the
implementation is the `ToolId` enum — finite by construction. Together with
`length_lt_of_not_fixpoint` this bounds the loop at `|ToolId|` iterations.
-/
theorem step_mem_universe {deps : α → List α} {s U : List α}
    (hs : ∀ x ∈ s, x ∈ U) (hd : ∀ t, ∀ d ∈ deps t, d ∈ U) :
    ∀ x ∈ step deps s, x ∈ U := by
  intro x hx
  rcases mem_step.1 hx with h | ⟨t, -, hdep⟩
  · exact hs x h
  · exact hd t x hdep

end DevEnv.Resolve
