# Tenets

## Why tenets?

Tenets are beliefs; ADRs are commitments. A tenet says what we hold true about people and the product, undated and unfalsifiable by events. An ADR spends that belief on one concrete choice, with a date and conditions for unwinding it.

## What are they?

Hardy thoughts: durable priors that shape decisions but are not
themselves decisions. A tenet sits upstream of the ADRs. When a
proposal and an ADR collide, the tenets are part of how we judge
whether the proposal is wrong or the ADR is due for revisiting. This
is a work-in-progress mental model, not spec; entries harden here
first and graduate into spec or ADR language when they earn it.

## 1. Losing work is unforgivable, even here

No one ever wants to lose work, to a pathological degree. The wider
market says so loudly: unlimited history is what products charge for.
An app that exists to forget does not get an exemption from that
instinct; it gets held to a higher bar, because every act of
forgetting is one misunderstanding away from feeling like loss. So
the clear and present data, everything inside its TTL, must be stored
robustly and securely, and plausibly fault tolerantly. Forgetting is
only trustworthy when it is visibly on schedule and never by
accident. The trustworthy-persistence milestone
(`docs/plans/trustworthy-persistence.md`, ADR-0016, ADR-0017) is this
tenet's first installment, not its discharge.

## 2. The artifact transcends the application

The stored artifact, meaning all data the app needs to reopen in the
same state as though it was just quit and reopened, should be thought
of as a thing in its own right, not as the app's scratch state. If
the experience is to be rock solid and durable enough that a person
learns to trust it, the artifact has to operate of its own accord:
the application is an editing interface over it, and it is the
properties of the artifact that determine when and how information
expires. The standing example: how should expirations work when the
application is not running? A file cannot destroy itself while
nothing executes, so the artifact's expiry semantics must be honest
about what is enforced at rest (key lifecycle, crypto erasure,
refusal to reveal expired content at next open) versus what needs a
running process. Wherever the app's behavior and the artifact's
properties disagree, the artifact's properties are the contract.

## 3. Do not wag the dog

An app that is steadfast to its beliefs is still only as good as how
well those beliefs map to what people actually want or need. We could
be perfectly ADR-abiding and still ship an app that sucks to use.
So: never treat "ADR-xyz says no" as the end of an argument about a
proposed idea. The question is always whether the idea is worthy of
revisiting ADR-xyz. Most of the time the answer is no and the ADR
stands, but it stands because it won the argument again, not because
it was cited. The eject-triggers section every ADR carries exists
precisely so decisions stay falsifiable; this tenet says the list of
triggers is never exhaustive, and a good idea is allowed to be one.
