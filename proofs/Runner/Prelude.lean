/-!
# What the Agda prelude was, in Lean core

The Agda proofs carried their own `Prelude`, so they checked with nothing but `agda`: no standard
library to install, pin, or keep in step with a compiler release. Lean core already has almost all
of it, and the port uses core's version rather than a copy. This module keeps the few lemmas core
does not have under the Agda names, and records where the rest went.

| Agda `Prelude` | Lean core |
|---|---|
| `_≡_`, `sym`, `trans`, `cong`, `cong₂`, `subst` | `Eq`, `Eq.symm`, `Eq.trans`, `congrArg`, `congr`, `▸` |
| `⊥`, `⊥-elim`, `¬_`, `⊤` | `False`, `absurd` / `nomatch`, `Not`, `True` |
| `Bool`, `not`, `_∨_`, `if_then_else_` | `Bool`, `!`, `\|\|`, `if … then … else` / `match` |
| `ℕ`, `suc-injective`, `_+_` | `Nat`, `Nat.succ.inj`, `+` |
| `_≤_`, `≤-refl`, `≤-suc`, `≤-trans` | `Nat.le`, `Nat.le_refl`, `Nat.le_succ_of_le`, `Nat.le_trans` |
| `Dec`, `DecEq`, `_≟ℕ_`, `×-dec`, `List-dec` | `Decidable`, `DecidableEq`, and core's instances for `Nat`, `×`, `List` |
| `_×_`, `Σ`, `_⊎_` | `∧` / `×`, `∃` / `Subtype`, `∨` |
| `Maybe`, `just-injective` | `Option`, `Option.some.inj` |
| `List`, `_∈_`, `_++_`, `any`, `filter` | `List`, `List.Mem`, `++`, `List.any`, `List.filter` |
| `All` | `∀ x ∈ xs, P x` |
| `∷-injective₁`, `∷-injective₂` | `List.cons.inj` |

Two differences matter to a reader of both. Lean's `+` recurses on its *right* argument and Agda's
on its left, so `+-zero` and `+-suc` are definitional here and `zero + n` is not; the proofs that
cared (`Runner.Regex`) use `omega` for the glue. And the Agda prelude's `infix 4 _≤_` declaration,
needed there because the default fixity bound tighter than `_+_`, has no counterpart: Lean's `≤`
already binds looser than `+`.
-/

namespace Runner.Prelude

/-- `+-zero`. Definitional in Lean, where `+` recurses on the right. -/
theorem plus_zero (m : Nat) : m + 0 = m := rfl

/-- `+-suc`. Also definitional here. -/
theorem plus_suc (m n : Nat) : m + (n + 1) = (m + n) + 1 := rfl

/-- `≤-loosen`: a bound one step weaker. -/
theorem le_loosen {m n : Nat} (h : m + 1 ≤ n) : m ≤ n := Nat.le_of_succ_le h

/-- `suc≰`: no number is above its successor. -/
theorem suc_not_le (n : Nat) : ¬ (n + 1 ≤ n) := Nat.not_succ_le_self n

/-- `+-mono`: adding the same amount on the left keeps a bound, which is what carries a bound on a
loop's tail back to where the loop started (`Runner.Regex`). -/
theorem plus_mono (k : Nat) {m n : Nat} (h : m ≤ n) : k + m ≤ k + n := Nat.add_le_add_left h k

/-- `filter-idempotent`: filtering twice by the same predicate is filtering once: what is kept is
already kept. -/
theorem filter_idempotent {α : Type} (p : α → Bool) :
    ∀ xs : List α, (xs.filter p).filter p = xs.filter p
  | [] => rfl
  | x :: xs => by
    cases h : p x with
    | false => simp only [List.filter_cons, h]; exact filter_idempotent p xs
    | true => simp only [List.filter_cons, h, ite_true]; exact congrArg (x :: ·) (filter_idempotent p xs)

end Runner.Prelude
