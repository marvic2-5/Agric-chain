;; -----------------------------------------------------------------------
;; AgriDAO.clar
;; Decentralized Cooperative Farming DAO (AgriDAO)
;; - Simple, readable, and Clarinet-friendly
;; -----------------------------------------------------------------------

;; Contract owner (set at deploy time)
(define-data-var owner principal tx-sender)

;; Member bookkeeping
;; members: map from principal -> { contribution: uint, joined: uint, active: bool }
(define-map members
  { member: principal }
  { contribution: uint, joined: uint, active: bool }
)

;; Index to list members (for UI / external indexing)
(define-data-var member-count uint u0)
(define-map member-index
  { idx: uint }
  { member: principal }
)

;; Totals
(define-data-var total-contributions uint u0)  ;; sum of all members' contributions stored
(define-data-var profit-pool uint u0)         ;; funds (STX) added for distribution to members
(define-data-var next-proposal-id uint u1)

;; Proposal structure
(define-map proposals
  { id: uint }
  {
    proposer: principal,
    recipient: principal,
    description: (string-ascii 200),
    amount-requested: uint,
    votes-for: uint,
    votes-against: uint,
    start-block: uint,
    end-block: uint,
    executed: bool,
    approved: bool
  }
)

;; Record per-proposal per-voter to prevent double-voting
(define-map votes
  { proposal-id: uint, voter: principal }
  { voted: bool, support: bool }
)

;; Events
;; define-event is not available in Clarity; use string constants for event names and emit via (print ...)
(define-constant member-registered "member-registered")
(define-constant contribution-added "contribution-added")
(define-constant contribution-withdrawn "contribution-withdrawn")
(define-constant proposal-created "proposal-created")
(define-constant vote-cast "vote-cast")
(define-constant proposal-finalized "proposal-finalized")
(define-constant funds-released "funds-released")
(define-constant profit-deposited "profit-deposited")
(define-constant profit-claimed "profit-claimed")
(define-constant member-penalized "member-penalized")
(define-constant owner-changed "owner-changed")

;; --------------------------
;; HELPERS / INTERNAL
;; --------------------------

(define-read-only (is-owner (p principal))
  (ok (is-eq (var-get owner) p))
)

(define-read-only (member-exists (p principal))
  (ok (is-some (map-get? members { member: p })))
)

;; safe-get-member returns member record or an error
(define-read-only (get-member-record (p principal))
  (match (map-get? members { member: p })
    m (ok m)
    (err "MEMBER_NOT_FOUND")
  )
)

;; --------------------------
;; MEMBER FUNCTIONS
;; --------------------------

;; Register as member and contribute STX in same tx (use stx-transfer)
;; Caller must send STX to the contract (amount > 0)
(define-public (register-member (amount uint))
  (let ((deposit amount)
        (caller tx-sender)
        (current-block stacks-block-height))
    (begin
      (asserts! (> deposit u0) (err "MUST_SEND_STX_TO_REGISTER"))
      (match (map-get? members { member: caller })
        some-member
        (err "ALREADY_MEMBER")
        (begin
          (map-set members { member: caller } { contribution: deposit, joined: current-block, active: true })
          ;; index member
          (let ((idx (var-get member-count)))
            (map-set member-index { idx: idx } { member: caller })
            (var-set member-count (+ idx u1))
          )
          ;; update totals
          (var-set total-contributions (+ (var-get total-contributions) deposit))
          (print (tuple (event member-registered) (data (tuple (member caller) (amount deposit)))))
          (ok deposit)
        )
      )
    )
  )
)

;; Add contribution to your existing membership
(define-public (add-contribution (amount uint))
  (let ((deposit amount) (caller tx-sender))
    (begin
      (asserts! (> deposit u0) (err "MUST_SEND_STX"))
      (match (map-get? members { member: caller })
        rec
        (let ((new-amt (+ (get contribution rec) deposit)))
          (map-set members { member: caller } { contribution: new-amt, joined: (get joined rec), active: true })
          (var-set total-contributions (+ (var-get total-contributions) deposit))
          (print (tuple (event contribution-added) (data (tuple (member caller) (amount deposit)))))
          (ok new-amt)
        )
        (err "NOT_A_MEMBER")
      )
    )
  )
)

;; Members can withdraw part of their contribution if not locked by proposals.
;; (For simplicity this contract does not account for "locked" contributions used in proposals.
;; In a production contract, you'd track locked funds separately.)
(define-public (withdraw-contribution (amount uint))
  (let ((caller tx-sender))
    (begin
      (asserts! (> amount u0) (err "INVALID_AMOUNT"))
      (match (map-get? members { member: caller })
        rec
        (let ((current (get contribution rec)))
          (asserts! (>= current amount) (err "INSUFFICIENT_CONTRIBUTION"))
          (let ((new-amt (- current amount)))
            (map-set members { member: caller } { contribution: new-amt, joined: (get joined rec), active: (get active rec) })
            (var-set total-contributions (- (var-get total-contributions) amount))
            ;; transfer STX from contract to member
            (match (stx-transfer? amount (as-contract tx-sender) caller)
              transfer-ok
              (begin
                (print (tuple (event contribution-withdrawn) (data (tuple (member caller) (amount amount)))))
                (ok new-amt)
              )
              transfer-err
              (err "TRANSFER_FAILED")
            )
          )
        )
        (err "NOT_A_MEMBER")
      )
    )
  )
)

;; --------------------------
;; PROPOSAL & VOTING
;; --------------------------

;; Create a proposal requesting funds
;; duration = number of blocks voting is open
(define-public (create-proposal (recipient principal) (description (string-ascii 200)) (amount-requested uint) (duration uint))
  (let ((proposer tx-sender)
        (start stacks-block-height)
        (id (var-get next-proposal-id)))
    (begin
      (asserts! (> duration u0) (err "DURATION_MUST_BE_POSITIVE"))
      (map-set proposals { id: id }
        {
          proposer: proposer,
          recipient: recipient,
          description: description,
          amount-requested: amount-requested,
          votes-for: u0,
          votes-against: u0,
          start-block: start,
          end-block: (+ start duration),
          executed: false,
          approved: false
        }
      )
      (var-set next-proposal-id (+ id u1))
      (print (tuple (event proposal-created) (data (tuple (id id) (proposer proposer) (recipient recipient) (amount amount-requested)))))
      (ok id)
    )
  )
)

;; Vote on a proposal. support = true (for) or false (against)
(define-public (vote-on-proposal (proposal-id uint) (support bool))
  (let ((voter tx-sender) (now stacks-block-height))
    (begin
      ;; must be a member
      (asserts! (is-some (map-get? members { member: voter })) (err "NOT_A_MEMBER"))
      ;; proposal must exist
      (match (map-get? proposals { id: proposal-id })
        p
          (begin
            ;; check voting window
            (asserts! (>= (get end-block p) now) (err "VOTING_CLOSED"))
            (asserts! (<= (get start-block p) now) (err "VOTING_NOT_STARTED"))
            ;; check voter hasn't voted
            (match (map-get? votes { proposal-id: proposal-id, voter: voter })
              v (err "ALREADY_VOTED")
              (begin
                ;; record vote
                (map-set votes { proposal-id: proposal-id, voter: voter } { voted: true, support: support })
                (if support
                    (map-set proposals { id: proposal-id }
                      (let ((old (unwrap-panic (map-get? proposals { id: proposal-id }))))
                        {
                          proposer: (get proposer old),
                          recipient: (get recipient old),
                          description: (get description old),
                          amount-requested: (get amount-requested old),
                          votes-for: (+ (get votes-for old) u1),
                          votes-against: (get votes-against old),
                          start-block: (get start-block old),
                          end-block: (get end-block old),
                          executed: (get executed old),
                          approved: (get approved old)
                        }
                      )
                    )
                    (map-set proposals { id: proposal-id }
                      (let ((old (unwrap-panic (map-get? proposals { id: proposal-id }))))
                        {
                          proposer: (get proposer old),
                          recipient: (get recipient old),
                          description: (get description old),
                          amount-requested: (get amount-requested old),
                          votes-for: (get votes-for old),
                          votes-against: (+ (get votes-against old) u1),
                          start-block: (get start-block old),
                          end-block: (get end-block old),
                          executed: (get executed old),
                          approved: (get approved old)
                        }
                      )
                    )
                )
                (print (tuple (event vote-cast) (data (tuple (proposal-id proposal-id) (voter voter) (support support)))))
                (ok "VOTE_RECORDED")
              )
            )
          )
        (err "PROPOSAL_NOT_FOUND")
      )
    )
  )
)

;; Finalize proposal after voting window ends.
;; Anyone can call finalize; it marks approved/denied and, if approved and funds available, releases funds.
(define-public (finalize-proposal (proposal-id uint))
  (let ((now stacks-block-height) (id proposal-id))
    (begin
      (match (map-get? proposals { id: id })
        p
        (begin
          (asserts! (not (get executed p)) (err "ALREADY_EXECUTED"))
          (asserts! (< (get end-block p) now) (err "VOTING_STILL_ACTIVE"))
          ;; simple majority: votes-for > votes-against and at least one vote
          (let ((vf (get votes-for p)) (va (get votes-against p)))
            (let ((approved (and (> vf va) (> (+ vf va) u0))))
              ;; update executed and approved flags
              (map-set proposals { id: id }
                {
                  proposer: (get proposer p),
                  recipient: (get recipient p),
                  description: (get description p),
                  amount-requested: (get amount-requested p),
                  votes-for: vf,
                  votes-against: va,
                  start-block: (get start-block p),
                  end-block: (get end-block p),
                  executed: true,
                  approved: approved
                }
              )
              (print (tuple (event proposal-finalized) (data (tuple (proposal-id id) (approved approved)))))
              (if approved
                  (let ((amt (get amount-requested p))
                        (rcp (get recipient p)))
                    (begin
                      (asserts! (>= (stx-get-balance (as-contract tx-sender)) amt) (err "CONTRACT_FUNDS_INSUFFICIENT"))
                      ;; transfer STX from contract to recipient
                      (match (stx-transfer? amt (as-contract tx-sender) rcp)
                        ok-val
                        (begin
                          (print (tuple (event funds-released) (data (tuple (proposal-id id) (recipient rcp) (amount amt)))))
                          (ok (tuple (result "PROPOSAL_APPROVED_AND_FUNDS_RELEASED") (amount amt)))
                        )
                        err-val
                        (err "TRANSFER_FAILED")
                      )
                    )
                  )
                  (ok (tuple (result "PROPOSAL_NOT_APPROVED") (amount u0)))
              )
            )
          )
        )
        (err "PROPOSAL_NOT_FOUND")
      )
    )
  )
)

;; --------------------------
;; PROFIT POOL & CLAIMS
;; --------------------------

;; Owner or any account can deposit profits to the profit pool by sending STX to this function.
(define-public (deposit-profits (amount uint))
  (let ((depositor tx-sender))
    (begin
      (asserts! (> amount u0) (err "NO_STX_SENT"))
      (var-set profit-pool (+ (var-get profit-pool) amount))
      (print (tuple (event profit-deposited) (data (tuple (depositor depositor) (amount amount)))))
      (ok (var-get profit-pool))
    )
  )
)

;; Members claim their pro-rata share from profit-pool.
;; Calculated as floor(profit-pool * member-contribution / total-contributions) - already-claimed.
(define-map claimed-profits
  { member: principal }
  { claimed: uint }
)

(define-public (claim-profit)
  (let ((caller tx-sender))
    (begin
      (asserts! (is-some (map-get? members { member: caller })) (err "NOT_A_MEMBER"))
      (let ((member-rec (unwrap-panic (map-get? members { member: caller })))
            (pool (var-get profit-pool))
            (total (var-get total-contributions)))
        (asserts! (> pool u0) (err "NO_PROFITS_AVAILABLE"))
        (asserts! (> total u0) (err "NO_TOTAL_CONTRIBUTIONS"))
        (let ((contrib (get contribution member-rec)))
          ;; calculate full entitlement (integer math)
          (let ((entitled (/ (* pool contrib) total)))
            (let ((already (default-to u0 (get claimed (map-get? claimed-profits { member: caller })))))
              (asserts! (> entitled already) (err "NO_UNCLAIMED_PROFIT"))
              (let ((payout (- entitled already)))
                ;; update claimed map
                (map-set claimed-profits { member: caller } { claimed: entitled })
                ;; reduce profit-pool by payout
                (var-set profit-pool (- (var-get profit-pool) payout))
                ;; transfer payout
                (match (stx-transfer? payout (as-contract tx-sender) caller)
                  ok-val
                  (begin
                    (print (tuple (event profit-claimed) (data (tuple (member caller) (amount payout)))))
                    (ok payout)
                  )
                  err-val
                  (err "TRANSFER_FAILED")
                )
              )
            )
          )
        )
      )
    )
  )
)

;; --------------------------
;; ADMIN / OWNER ACTIONS
;; --------------------------

;; Penalize a member by reducing their recorded contribution (and optionally move penalty to profit-pool)
(define-public (penalize-member (member principal) (amount uint))
  (let ((caller tx-sender))
    (begin
      (asserts! (is-eq (var-get owner) caller) (err "UNAUTHORIZED"))
      (asserts! (> amount u0) (err "INVALID_AMOUNT"))
      (match (map-get? members { member: member })
        rec
        (let ((current (get contribution rec)))
          (asserts! (>= current amount) (err "PENALTY_EXCEEDS_CONTRIBUTION"))
          (let ((new-amt (- current amount)))
            (map-set members { member: member } { contribution: new-amt, joined: (get joined rec), active: (get active rec) })
            (var-set total-contributions (- (var-get total-contributions) amount))
            ;; add penalty amount to profit-pool (could be assigned elsewhere)
            (var-set profit-pool (+ (var-get profit-pool) amount))
            (print (tuple (event member-penalized) (data (tuple (member member) (amount amount)))))
            (ok new-amt)
          )
        )
        (err "MEMBER_NOT_FOUND")
      )
    )
  )
)

;; Owner can change owner
(define-public (change-owner (new-owner principal))
  (let ((caller tx-sender))
    (begin
      (asserts! (is-eq (var-get owner) caller) (err "UNAUTHORIZED"))
      (let ((old (var-get owner)))
        (var-set owner new-owner)
        (print (tuple (event owner-changed) (data (tuple (old-owner old) (new-owner new-owner)))))
        (ok new-owner)
      )
    )
  )
)

;; Emergency: owner can withdraw STX from contract (use with caution)
(define-public (owner-withdraw (amount uint) (to principal))
  (let ((caller tx-sender))
    (begin
      (asserts! (is-eq (var-get owner) caller) (err "UNAUTHORIZED"))
      (asserts! (>= (stx-get-balance (as-contract tx-sender)) amount) (err "INSUFFICIENT_CONTRACT_BALANCE"))
      (match (stx-transfer? amount (as-contract tx-sender) to)
        ok-val
        (ok amount)
        err-val
        (err "TRANSFER_FAILED")
      )
    )
  )
)

;; --------------------------
;; READ-ONLY HELPERS
;; --------------------------

(define-read-only (get-member (p principal))
  (map-get? members { member: p })
)

(define-read-only (get-member-by-index (idx uint))
  (map-get? member-index { idx: idx })
)

(define-read-only (get-member-count)
  (ok (var-get member-count))
)

(define-read-only (get-total-contributions)
  (ok (var-get total-contributions))
)

(define-read-only (get-profit-pool)
  (ok (var-get profit-pool))
)

(define-read-only (get-proposal (id uint))
  (map-get? proposals { id: id })
)

(define-read-only (has-voted (proposal-id uint) (voter principal))
  (map-get? votes { proposal-id: proposal-id, voter: voter })
)
