/-!
# Managed-path boundary

Models the two ownership predicates that gate every destructive filesystem
operation in dev-env:

* `configs.isManagedTarget` — may we replace this symlink in `$HOME`?
* `apply.isManagedExecutable` — may we replace this executable link in `<bin>`?

Both are the same byte-level test: a string prefix check *plus* a path-component
boundary check. Dropping the boundary check turns
`~/.local/share/dev-env/stow-source` into a prefix of the unrelated
`~/.local/share/dev-env/stow-sources-fake`, which would make dev-env delete a
path it does not own. The theorems below pin that boundary down.

Paths are modelled as `List Char`, i.e. raw bytes — deliberately *not* as a list
of components, because the whole point is that a byte-prefix is not a path
prefix.
-/

namespace DevEnv.Managed

/-- `std.mem.startsWith(u8, haystack, needle)`. -/
def startsWith : List Char → List Char → Bool
  | _, [] => true
  | [], _ :: _ => false
  | a :: as, b :: bs => (a == b) && startsWith as bs

/--
`isManagedTarget` / `isManagedExecutable` for a single root:

```zig
std.mem.startsWith(u8, resolved, root) and
    (resolved.len == root.len or resolved[root.len] == '/')
```
-/
def underRoot (p r : List Char) : Bool :=
  startsWith p r && (p.length == r.length || (p.drop r.length).head? == some '/')

/-- The multi-root form: `isManagedTarget(resolved, managed_roots)`. -/
def underAnyRoot (p : List Char) (roots : List (List Char)) : Bool :=
  roots.any (underRoot p)

/-! ## The prefix test -/

theorem startsWith_iff (r p : List Char) :
    startsWith p r = true ↔ ∃ rest, p = r ++ rest := by
  induction r generalizing p with
  | nil => simp [startsWith]
  | cons b bs ih =>
    cases p with
    | nil => simp [startsWith]
    | cons a as =>
      simp only [startsWith, Bool.and_eq_true, beq_iff_eq, ih, List.cons_append,
        List.cons.injEq]
      constructor
      · rintro ⟨rfl, rest, rfl⟩; exact ⟨rest, rfl, rfl⟩
      · rintro ⟨rest, rfl, rfl⟩; exact ⟨rfl, rest, rfl⟩

theorem startsWith_append (r rest : List Char) : startsWith (r ++ rest) r = true :=
  (startsWith_iff r (r ++ rest)).2 ⟨rest, rfl⟩

/-! ## Soundness: acceptance implies a genuine path-component prefix -/

/--
The safety theorem. If `underRoot` accepts a path, that path is either the root
itself or lies strictly beneath it at a `/` boundary. Nothing else is ever
accepted, so a path dev-env is willing to delete really is one it owns.
-/
theorem underRoot_sound {p r : List Char} (h : underRoot p r = true) :
    p = r ∨ ∃ rest, p = r ++ '/' :: rest := by
  simp only [underRoot, Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at h
  obtain ⟨hpre, hbound⟩ := h
  obtain ⟨rest, rfl⟩ := (startsWith_iff r p).1 hpre
  rw [List.drop_left] at hbound
  cases hbound with
  | inl hlen =>
    left
    have : rest = [] := by
      have := hlen
      simp only [List.length_append] at this
      exact List.eq_nil_of_length_eq_zero (by omega)
    simp [this]
  | inr hslash =>
    right
    cases rest with
    | nil => simp at hslash
    | cons c t =>
      simp only [List.head?_cons, Option.some.injEq] at hslash
      exact ⟨t, by simp [hslash]⟩

/-! ## Completeness: everything genuinely under the root is accepted -/

theorem startsWith_self (r : List Char) : startsWith r r = true := by
  simpa using startsWith_append r []

theorem underRoot_self (r : List Char) : underRoot r r = true := by
  simp [underRoot, startsWith_self]

theorem underRoot_child (r rest : List Char) :
    underRoot (r ++ '/' :: rest) r = true := by
  simp [underRoot, startsWith_append]

/-! ## The sibling-prefix rejection -/

/--
A path that shares the root's bytes but continues with anything other than `/`
is a *different* path (a sibling whose name merely starts the same way) and is
always rejected.
-/
theorem underRoot_sibling_rejected {r rest : List Char} {c : Char} (hc : c ≠ '/') :
    underRoot (r ++ c :: rest) r = false := by
  simp only [underRoot, List.drop_left, Bool.and_eq_false_iff, Bool.or_eq_false_iff,
    beq_eq_false_iff_ne, ne_eq]
  right
  refine ⟨?_, ?_⟩
  · simp
  · simp [hc]

/-- A path shorter than the root is rejected. -/
theorem underRoot_shorter_rejected {p r : List Char} (h : p.length < r.length) :
    underRoot p r = false := by
  cases hu : underRoot p r with
  | false => rfl
  | true =>
    exfalso
    rcases underRoot_sound hu with rfl | ⟨rest, rfl⟩
    · omega
    · simp only [List.length_append, List.length_cons] at h; omega

/-! ## Regression: the concrete case the boundary check exists for -/

example :
    underRoot "/data/dev-env/stow-sources-fake".toList
      "/data/dev-env/stow-source".toList = false := by
  decide

example :
    underRoot "/data/dev-env/stow-source/nvim".toList
      "/data/dev-env/stow-source".toList = true := by
  decide

/-- Sibling rejection holds for *every* root and every sibling suffix. -/
theorem no_sibling_is_ever_managed (r suffix : List Char) (c : Char) (hc : c ≠ '/')
    (roots : List (List Char)) (hroots : ∀ x ∈ roots, x = r) :
    underAnyRoot (r ++ c :: suffix) roots = false := by
  simp only [underAnyRoot, List.any_eq_false]
  intro x hx
  rw [hroots x hx]
  simp [underRoot_sibling_rejected hc]

end DevEnv.Managed
