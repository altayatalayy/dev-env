--------------------------- MODULE DevEnvApply ---------------------------
(***************************************************************************)
(* The dev-env apply/uninstall lifecycle, with crash injection.            *)
(*                                                                         *)
(* Models `dev_env/apply.zig`, `dev_env/uninstall.zig`, and the state      *)
(* files they read and write. "Crash" here is not only power loss: a       *)
(* failed download, a failing build step, and a config conflict all abort  *)
(* `applyOutcome` after some side effects have already landed.             *)
(*                                                                         *)
(* Two different notions of "recorded" matter, and `installed.json`        *)
(* already separates them:                                                 *)
(*                                                                         *)
(*   recTools / recConfigs  what is INSTALLED. Drives `computeDiff`.       *)
(*                          Over-claiming here is fatal: apply concludes   *)
(*                          there is nothing to do and never repairs the   *)
(*                          machine.                                       *)
(*   recOwned               what dev-env MAY DELETE (`owned_prefixes` and  *)
(*                          `owned_symlinks`). Drives `clean` and          *)
(*                          `uninstall`. Over-claiming here is harmless:   *)
(*                          deleting an absent path is a no-op.            *)
(*                                                                         *)
(* Since no "mutate the machine, then write the receipt" pair is atomic,   *)
(* the only way to stay safe across a crash is to pick, per field, the     *)
(* direction whose transient error is the harmless one:                    *)
(*                                                                         *)
(*   recOwned  grows BEFORE creating, shrinks AFTER destroying (optimistic)*)
(*   recTools  shrinks BEFORE destroying, grows AFTER creating (pessimistic)*)
(*                                                                         *)
(* SavePolicy selects the implementation under test:                       *)
(*   "final"         today: a single receipt write, after every side effect*)
(*   "after_install" persist once more right after tools are installed     *)
(*   "write_ahead"   also record intended ownership before creating        *)
(*   "two_phase"     the above, plus drop removed tools from the installed *)
(*                   claim *before* deleting them                          *)
(***************************************************************************)
EXTENDS FiniteSets, Naturals

CONSTANTS
    Tools,        \* tool names; each tool owns exactly one config package
    Releases,     \* installer release ids
    MaxPlans,     \* bound on how often the user re-plans (keeps the model finite)
    SavePolicy

NoRel == "none"

VARIABLES
    hasLock, lockRelease, lockTools,      \* lock.json (desired)
    hasReceipt, recRelease, recTools,     \* installed.json: what is installed
    recConfigs,                           \*   "          " : configs applied
    recOwned,                             \*   "          " : what we may delete
    disk,                                 \* <opt>/<tool> trees that exist
    stowed,                               \* config packages linked into $HOME
    phase,                                \* progress of the in-flight apply
    diffInstall, diffRemove, diffRemoveConfigs,
    plans

vars == <<hasLock, lockRelease, lockTools, hasReceipt, recRelease, recTools,
          recConfigs, recOwned, disk, stowed, phase, diffInstall, diffRemove,
          diffRemoveConfigs, plans>>

Phases == {"idle", "reserving", "removing", "installing", "persisting",
           "configuring", "saving"}

TypeOK ==
    /\ hasLock \in BOOLEAN
    /\ lockRelease \in Releases \cup {NoRel}
    /\ lockTools \subseteq Tools
    /\ hasReceipt \in BOOLEAN
    /\ recRelease \in Releases \cup {NoRel}
    /\ recTools \subseteq Tools
    /\ recConfigs \subseteq Tools
    /\ recOwned \subseteq Tools
    /\ disk \subseteq Tools
    /\ stowed \subseteq Tools
    /\ phase \in Phases
    /\ diffInstall \subseteq Tools
    /\ diffRemove \subseteq Tools
    /\ diffRemoveConfigs \subseteq Tools
    /\ plans \in 0..MaxPlans

Init ==
    /\ hasLock = FALSE /\ lockRelease = NoRel /\ lockTools = {}
    /\ hasReceipt = FALSE /\ recRelease = NoRel /\ recTools = {}
    /\ recConfigs = {} /\ recOwned = {}
    /\ disk = {} /\ stowed = {}
    /\ phase = "idle"
    /\ diffInstall = {} /\ diffRemove = {} /\ diffRemoveConfigs = {}
    /\ plans = 0

(***************************************************************************)
(* planner.computeDiff                                                     *)
(***************************************************************************)

InstallSet ==
    IF ~hasReceipt THEN lockTools
    ELSE IF recRelease # lockRelease THEN lockTools
    ELSE lockTools \ recTools

RemoveSet == IF ~hasReceipt THEN {} ELSE recTools \ lockTools

RemoveConfigSet == IF ~hasReceipt THEN {} ELSE recConfigs \ lockTools

DiffEmpty ==
    /\ hasReceipt
    /\ recRelease = lockRelease
    /\ InstallSet = {}
    /\ RemoveSet = {}
    /\ recConfigs = lockTools

(***************************************************************************)
(* Actions                                                                 *)
(***************************************************************************)

Receipt == <<hasReceipt, recRelease, recTools, recConfigs, recOwned>>
Lock == <<hasLock, lockRelease, lockTools>>
DiffV == <<diffInstall, diffRemove, diffRemoveConfigs>>

Reserving == SavePolicy \in {"write_ahead", "two_phase"}
Pessimistic == SavePolicy = "two_phase"

\* `dev-env plan --tools ...`: the user changes the desired state.
Plan ==
    /\ phase = "idle"
    /\ plans < MaxPlans
    /\ \E r \in Releases, ts \in SUBSET Tools :
        /\ hasLock' = TRUE
        /\ lockRelease' = r
        /\ lockTools' = ts
    /\ plans' = plans + 1
    /\ UNCHANGED <<Receipt, disk, stowed, phase, DiffV>>

\* apply.applyOutcome: snapshot the diff, then do the work. An empty diff
\* short-circuits, which is why this is guarded by ~DiffEmpty.
ApplyStart ==
    /\ phase = "idle"
    /\ hasLock
    /\ ~DiffEmpty
    /\ diffInstall' = InstallSet
    /\ diffRemove' = RemoveSet
    /\ diffRemoveConfigs' = RemoveConfigSet
    /\ phase' = IF Reserving THEN "reserving" ELSE "removing"
    /\ UNCHANGED <<Lock, Receipt, disk, stowed, plans>>

\* Declare what this run may create before creating it, and (two_phase) give up
\* the installed-claim on everything about to be deleted.
Reserve ==
    /\ phase = "reserving"
    /\ hasReceipt' = TRUE
    /\ recOwned' = recOwned \cup disk \cup stowed \cup diffInstall \cup lockTools
    /\ recTools' = IF Pessimistic THEN recTools \ diffRemove ELSE recTools
    /\ recConfigs' = IF Pessimistic THEN recConfigs \ diffRemoveConfigs ELSE recConfigs
    /\ phase' = "removing"
    /\ UNCHANGED <<Lock, recRelease, disk, stowed, DiffV, plans>>

\* apply.uninstallRemovedTools, through the installer recorded in the receipt.
Remove ==
    /\ phase = "removing"
    /\ disk' = disk \ diffRemove
    /\ phase' = "installing"
    /\ UNCHANGED <<Lock, Receipt, stowed, DiffV, plans>>

\* client.applyTools: archives extracted, sources built, bin links created.
Install ==
    /\ phase = "installing"
    /\ disk' = disk \cup diffInstall
    /\ phase' = IF SavePolicy = "final" THEN "configuring" ELSE "persisting"
    /\ UNCHANGED <<Lock, Receipt, stowed, DiffV, plans>>

\* Persist what is now installed before touching $HOME.
SaveTools ==
    /\ phase = "persisting"
    /\ hasReceipt' = TRUE
    /\ recRelease' = lockRelease
    /\ recTools' = disk
    /\ recConfigs' = recConfigs \cap stowed
    /\ recOwned' = recOwned \cup disk \cup stowed
    /\ phase' = "configuring"
    /\ UNCHANGED <<Lock, disk, stowed, DiffV, plans>>

\* Extract dotfiles, resolve conflicts, sync stow-source, stow, apply-configs.
Configs ==
    /\ phase = "configuring"
    /\ stowed' = lockTools
    /\ phase' = "saving"
    /\ UNCHANGED <<Lock, Receipt, disk, DiffV, plans>>

\* receipt_mod.save at the end of applyOutcome.
SaveReceipt ==
    /\ phase = "saving"
    /\ hasReceipt' = TRUE
    /\ recRelease' = lockRelease
    /\ recTools' = disk
    /\ recConfigs' = stowed
    /\ recOwned' = recOwned \cup disk \cup stowed
    /\ phase' = "idle"
    /\ UNCHANGED <<Lock, disk, stowed, DiffV, plans>>

\* Power loss, SIGKILL, a failed download, a failing build step, or a config
\* conflict: the run stops without reaching its receipt write.
Crash ==
    /\ phase # "idle"
    /\ phase' = "idle"
    /\ UNCHANGED <<Lock, Receipt, disk, stowed, DiffV, plans>>

\* uninstall.run: unstow recorded packages, remove recorded tools, drop state.
\* It can only act on what the receipt records -- that is the whole point.
Uninstall ==
    /\ phase = "idle"
    /\ hasReceipt
    /\ stowed' = stowed \ (recConfigs \cup recOwned)
    /\ disk' = disk \ (recTools \cup recOwned)
    /\ hasReceipt' = FALSE
    /\ recRelease' = NoRel /\ recTools' = {} /\ recConfigs' = {} /\ recOwned' = {}
    /\ hasLock' = FALSE /\ lockRelease' = NoRel /\ lockTools' = {}
    /\ UNCHANGED <<phase, DiffV, plans>>

NextNoCrash ==
    \/ Plan \/ ApplyStart \/ Reserve \/ Remove \/ Install \/ SaveTools
    \/ Configs \/ SaveReceipt \/ Uninstall

Next == NextNoCrash \/ Crash

Spec == Init /\ [][Next]_vars

SpecNoCrash == Init /\ [][NextNoCrash]_vars

FairSpecNoCrash ==
    /\ SpecNoCrash
    /\ WF_vars(ApplyStart) /\ WF_vars(Reserve) /\ WF_vars(Remove)
    /\ WF_vars(Install) /\ WF_vars(SaveTools) /\ WF_vars(Configs)
    /\ WF_vars(SaveReceipt)

(***************************************************************************)
(* Invariants                                                              *)
(***************************************************************************)

\* Everything dev-env put on the machine is recorded as removable, so `clean`
\* and `uninstall` can always reclaim it. Checked when no apply is running.
OwnershipComplete ==
    (phase = "idle") =>
        /\ disk \subseteq (recTools \cup recOwned)
        /\ stowed \subseteq (recConfigs \cup recOwned)

\* A completed uninstall leaves nothing of ours behind.
UninstallLeavesNothing ==
    (phase = "idle" /\ ~hasReceipt) => (disk = {} /\ stowed = {})

\* The receipt never claims something is installed when it is not. Violating
\* this is unrecoverable: `computeDiff` sees the tool as present, so apply
\* refuses to reinstall it no matter how often it is run.
NoPhantomInstall ==
    (phase = "idle") =>
        /\ recTools \subseteq disk
        /\ recConfigs \subseteq stowed

\* When apply reports "nothing to change", everything the lock asks for really
\* is on the machine. (Extra inactive files may remain -- that is what `clean`
\* is for -- but nothing desired may be missing.)
DiffEmptyMeansDesiredPresent ==
    (phase = "idle" /\ hasLock /\ DiffEmpty) =>
        /\ lockTools \subseteq disk
        /\ lockTools \subseteq stowed

(***************************************************************************)
(* Liveness (crash-free runs)                                              *)
(***************************************************************************)

Converged ==
    /\ phase = "idle"
    /\ disk = lockTools
    /\ stowed = lockTools
    /\ recTools = lockTools
    /\ recConfigs = lockTools
    /\ recRelease = lockRelease

\* Once the user stops re-planning, apply drives the machine to the lock.
EventuallyConverges ==
    (plans = MaxPlans /\ hasLock) ~> (Converged \/ ~hasLock)

=============================================================================
