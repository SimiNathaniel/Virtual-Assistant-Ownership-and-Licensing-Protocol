(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-assistant-not-found (err u102))
(define-constant err-insufficient-payment (err u103))
(define-constant err-license-expired (err u104))
(define-constant err-skill-not-found (err u105))
(define-constant err-invalid-royalty (err u106))
(define-constant err-invalid-rating (err u107))
(define-constant err-already-rated (err u108))
(define-constant err-not-licensed (err u109))
(define-constant err-already-reported (err u110))

(define-non-fungible-token virtual-assistant uint)

(define-data-var next-assistant-id uint u1)
(define-data-var platform-fee-percentage uint u500)

(define-data-var platform-fee-balance uint u0)

(define-map assistants
  uint
  {
    name: (string-ascii 64),
    description: (string-ascii 256),
    owner: principal,
    creator: principal,
    royalty-percentage: uint,
    license-price: uint,
    skills: (list 10 uint),
    usage-count: uint,
    created-at: uint,
    is-licensable: bool,
    is-paused: bool
  }
)

(define-map licenses
  {assistant-id: uint, licensee: principal}
  {
    expires-at: uint,
    usage-limit: uint,
    remaining-usage: uint,
    paid-amount: uint,
    granted-at: uint
  }
)

(define-map skills
  uint
  {
    name: (string-ascii 32),
    description: (string-ascii 128),
    creator: principal,
    price: uint,
    usage-count: uint,
    is-active: bool
  }
)

(define-data-var next-skill-id uint u1)

(define-map skill-owners
  {skill-id: uint, owner: principal}
  {installed-at: uint}
)

(define-map royalty-balances
  principal
  uint
)

(define-map ratings
  {assistant-id: uint, rater: principal}
  {
    score: uint,
    review: (string-ascii 128),
    created-at: uint
  }
)

(define-map assistant-ratings
  uint
  {
    total-score: uint,
    total-ratings: uint,
    average-rating: uint
  }
)
(define-map reports
  {assistant-id: uint, reporter: principal}
  {
    reason: (string-ascii 128),
    reported-at: uint
  }
)

(define-map assistant-reports
  uint
  uint
)

(define-public (report-assistant (assistant-id uint) (reason (string-ascii 128)))
  (let
    (
      (existing-report (map-get? reports {assistant-id: assistant-id, reporter: tx-sender}))
    )
    (asserts! (is-none existing-report) err-already-reported)
    (map-set reports
      {assistant-id: assistant-id, reporter: tx-sender}
      {
        reason: reason,
        reported-at: burn-block-height
      }
    )
    (map-set assistant-reports assistant-id
      (+ (default-to u0 (map-get? assistant-reports assistant-id)) u1)
    )
    (ok true)
  )
)
(define-map user-favorites {user: principal, assistant-id: uint} bool)

(define-public (mint-assistant (name (string-ascii 64)) (description (string-ascii 256)) (royalty-percentage uint) (license-price uint))
  (let
    (
      (assistant-id (var-get next-assistant-id))
    )
    (asserts! (<= royalty-percentage u10000) err-invalid-royalty)
    (try! (nft-mint? virtual-assistant assistant-id tx-sender))
    (map-set assistants assistant-id
      {
        name: name,
        description: description,
        owner: tx-sender,
        creator: tx-sender,
        royalty-percentage: royalty-percentage,
        license-price: license-price,
        skills: (list),
        usage-count: u0,
        created-at: burn-block-height,
        is-licensable: true,
        is-paused: false
      }
    )
    (var-set next-assistant-id (+ assistant-id u1))
    (ok assistant-id)
  )
)

(define-public (transfer-assistant (assistant-id uint) (new-owner principal))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
    )
    (asserts! (is-eq tx-sender (get owner assistant)) err-not-authorized)
    (try! (nft-transfer? virtual-assistant assistant-id tx-sender new-owner))
    (map-set assistants assistant-id
      (merge assistant {owner: new-owner})
    )
    (ok true)
  )
)

(define-public (purchase-license (assistant-id uint) (duration-blocks uint) (usage-limit uint))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
      (license-cost (get license-price assistant))
      (total-cost (* license-cost duration-blocks))
      (platform-fee (/ (* total-cost (var-get platform-fee-percentage)) u10000))
      (creator-royalty (/ (* total-cost (get royalty-percentage assistant)) u10000))
      (owner-payment (- total-cost (+ platform-fee creator-royalty)))
    )
    (var-set platform-fee-balance (+ (var-get platform-fee-balance) platform-fee))
    (asserts! (get is-licensable assistant) err-not-authorized)
    (asserts! (not (get is-paused assistant)) err-not-authorized)
    (try! (stx-transfer? total-cost tx-sender (as-contract tx-sender)))
    (try! (as-contract (stx-transfer? owner-payment tx-sender (get owner assistant))))
    (try! (as-contract (stx-transfer? creator-royalty tx-sender (get creator assistant))))
    (map-set licenses
      {assistant-id: assistant-id, licensee: tx-sender}
      {
        expires-at: (+ burn-block-height duration-blocks),
        usage-limit: usage-limit,
        remaining-usage: usage-limit,
        paid-amount: total-cost,
        granted-at: burn-block-height
      }
    )
    (map-set royalty-balances
      (get creator assistant)
      (+ 
        (default-to u0 (map-get? royalty-balances (get creator assistant)))
        creator-royalty
      )
    )
    (ok true)
  )
)

(define-public (renew-license (assistant-id uint) (additional-duration-blocks uint) (additional-usage uint))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
      (existing-license (unwrap! (map-get? licenses {assistant-id: assistant-id, licensee: tx-sender}) err-not-authorized))
      (license-cost (get license-price assistant))
      (renewal-cost (* license-cost additional-duration-blocks))
      (platform-fee (/ (* renewal-cost (var-get platform-fee-percentage)) u10000))
      (creator-royalty (/ (* renewal-cost (get royalty-percentage assistant)) u10000))
      (owner-payment (- renewal-cost (+ platform-fee creator-royalty)))
      (new-expires-at (+ (get expires-at existing-license) additional-duration-blocks))
      (new-remaining-usage (+ (get remaining-usage existing-license) additional-usage))
      (new-paid-amount (+ (get paid-amount existing-license) renewal-cost))
    )
    (asserts! (get is-licensable assistant) err-not-authorized)
    (asserts! (not (get is-paused assistant)) err-not-authorized)
    (try! (stx-transfer? renewal-cost tx-sender (as-contract tx-sender)))
    (try! (as-contract (stx-transfer? owner-payment tx-sender (get owner assistant))))
    (try! (as-contract (stx-transfer? creator-royalty tx-sender (get creator assistant))))
    (var-set platform-fee-balance (+ (var-get platform-fee-balance) platform-fee))
    (map-set licenses
      {assistant-id: assistant-id, licensee: tx-sender}
      (merge existing-license
        {
          expires-at: new-expires-at,
          remaining-usage: new-remaining-usage,
          paid-amount: new-paid-amount
        }
      )
    )
    (map-set royalty-balances
      (get creator assistant)
      (+
        (default-to u0 (map-get? royalty-balances (get creator assistant)))
        creator-royalty
      )
    )
    (ok true)
  )
)

(define-public (use-assistant (assistant-id uint))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
      (license (unwrap! (map-get? licenses {assistant-id: assistant-id, licensee: tx-sender}) err-not-authorized))
    )
    (asserts! (> (get expires-at license) burn-block-height) err-license-expired)
    (asserts! (> (get remaining-usage license) u0) err-insufficient-payment)
    (asserts! (not (get is-paused assistant)) err-not-authorized)
    (map-set licenses
      {assistant-id: assistant-id, licensee: tx-sender}
      (merge license {remaining-usage: (- (get remaining-usage license) u1)})
    )
    (map-set assistants assistant-id
      (merge assistant {usage-count: (+ (get usage-count assistant) u1)})
    )
    (ok true)
  )
)

(define-public (transfer-license (assistant-id uint) (new-licensee principal))
  (let
    (
      (current-license (unwrap! (map-get? licenses {assistant-id: assistant-id, licensee: tx-sender}) err-not-authorized))
    )
    (map-delete licenses {assistant-id: assistant-id, licensee: tx-sender})
    (map-set licenses {assistant-id: assistant-id, licensee: new-licensee} current-license)
    (ok true)
  )
)

(define-public (create-skill (name (string-ascii 32)) (description (string-ascii 128)) (price uint))
  (let
    (
      (skill-id (var-get next-skill-id))
    )
    (map-set skills skill-id
      {
        name: name,
        description: description,
        creator: tx-sender,
        price: price,
        usage-count: u0,
        is-active: true
      }
    )
    (var-set next-skill-id (+ skill-id u1))
    (ok skill-id)
  )
)

(define-public (install-skill (assistant-id uint) (skill-id uint))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
      (skill (unwrap! (map-get? skills skill-id) err-skill-not-found))
      (skill-cost (get price skill))
      (current-skills (get skills assistant))
    )
    (asserts! (is-eq tx-sender (get owner assistant)) err-not-authorized)
    (asserts! (get is-active skill) err-skill-not-found)
    (asserts! (< (len current-skills) u10) err-insufficient-payment)
    (try! (stx-transfer? skill-cost tx-sender (get creator skill)))
    (map-set assistants assistant-id
      (merge assistant {skills: (unwrap! (as-max-len? (append current-skills skill-id) u10) err-insufficient-payment)})
    )
    (map-set skill-owners
      {skill-id: skill-id, owner: tx-sender}
      {installed-at: burn-block-height}
    )
    (map-set skills skill-id
      (merge skill {usage-count: (+ (get usage-count skill) u1)})
    )
    (ok true)
  )
)

(define-public (toggle-licensable (assistant-id uint))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
    )
    (asserts! (is-eq tx-sender (get owner assistant)) err-not-authorized)
    (map-set assistants assistant-id
      (merge assistant {is-licensable: (not (get is-licensable assistant))})
    )
    (ok true)
  )
)

(define-public (update-license-price (assistant-id uint) (new-price uint))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
    )
    (asserts! (is-eq tx-sender (get owner assistant)) err-not-authorized)
    (map-set assistants assistant-id
      (merge assistant {license-price: new-price})
    )
    (ok true)
  )
)

(define-public (toggle-pause (assistant-id uint))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
    )
    (asserts! (is-eq tx-sender (get owner assistant)) err-not-authorized)
    (map-set assistants assistant-id
      (merge assistant {is-paused: (not (get is-paused assistant))})
    )
    (ok true)
  )
)

(define-public (withdraw-royalties)
  (let
    (
      (balance (default-to u0 (map-get? royalty-balances tx-sender)))
    )
    (asserts! (> balance u0) err-insufficient-payment)
    (try! (as-contract (stx-transfer? balance tx-sender tx-sender)))
    (map-delete royalty-balances tx-sender)
    (ok balance)
  )
)

(define-public (withdraw-platform-fees)
  (let
    (
      (balance (var-get platform-fee-balance))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> balance u0) err-insufficient-payment)
    (try! (as-contract (stx-transfer? balance tx-sender tx-sender)))
    (var-set platform-fee-balance u0)
    (ok balance)
  )
)

(define-public (set-platform-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-fee u1000) err-invalid-royalty)
    (var-set platform-fee-percentage new-fee)
    (ok true)
  )
)

(define-public (rate-assistant (assistant-id uint) (score uint) (feedback (string-ascii 128)))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
      (existing-rating (map-get? ratings {assistant-id: assistant-id, rater: tx-sender}))
      (current-stats (default-to {total-score: u0, total-ratings: u0, average-rating: u0}
                                  (map-get? assistant-ratings assistant-id)))
      (has-license (is-some (map-get? licenses {assistant-id: assistant-id, licensee: tx-sender})))
    )
    (asserts! (and (>= score u1) (<= score u5)) err-invalid-rating)
    (asserts! (is-none existing-rating) err-already-rated)
    (asserts! has-license err-not-licensed)
    (map-set ratings
      {assistant-id: assistant-id, rater: tx-sender}
      {
        score: score,
        review: feedback,
        created-at: burn-block-height
      }
    )
    (let
      (
        (new-total-score (+ (get total-score current-stats) score))
        (new-total-ratings (+ (get total-ratings current-stats) u1))
        (new-average (/ (* new-total-score u100) new-total-ratings))
      )
      (map-set assistant-ratings assistant-id
        {
          total-score: new-total-score,
          total-ratings: new-total-ratings,
          average-rating: new-average
        }
      )
    )
    (ok true)
  )
)

(define-public (add-favorite (assistant-id uint))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
    )
    (asserts! (is-some (map-get? licenses {assistant-id: assistant-id, licensee: tx-sender})) err-not-licensed)
    (map-set user-favorites {user: tx-sender, assistant-id: assistant-id} true)
    (ok true)
  )
)
(define-public (remove-favorite (assistant-id uint))
  (begin
    (map-delete user-favorites {user: tx-sender, assistant-id: assistant-id})
    (ok true)
  )
)

(define-read-only (get-assistant (assistant-id uint))
  (map-get? assistants assistant-id)
)

(define-read-only (get-license (assistant-id uint) (licensee principal))
  (map-get? licenses {assistant-id: assistant-id, licensee: licensee})
)

(define-read-only (get-skill (skill-id uint))
  (map-get? skills skill-id)
)

(define-read-only (get-royalty-balance (user principal))
  (default-to u0 (map-get? royalty-balances user))
)

(define-read-only (get-next-assistant-id)
  (var-get next-assistant-id)
)

(define-read-only (get-next-skill-id)
  (var-get next-skill-id)
)

(define-read-only (get-platform-fee)
  (var-get platform-fee-percentage)
)

(define-read-only (get-platform-fee-balance)
  (var-get platform-fee-balance)
)

(define-read-only (is-license-valid (assistant-id uint) (licensee principal))
  (match (map-get? licenses {assistant-id: assistant-id, licensee: licensee})
    license (and 
              (> (get expires-at license) burn-block-height)
              (> (get remaining-usage license) u0)
            )
    false
  )
)

(define-read-only (get-assistant-owner (assistant-id uint))
  (nft-get-owner? virtual-assistant assistant-id)
)

(define-read-only (get-rating (assistant-id uint) (rater principal))
  (map-get? ratings {assistant-id: assistant-id, rater: rater})
)

(define-read-only (get-assistant-rating-stats (assistant-id uint))
  (map-get? assistant-ratings assistant-id)
)
(define-read-only (is-favorite (user principal) (assistant-id uint))
  (is-some (map-get? user-favorites {user: user, assistant-id: assistant-id}))
)

(define-read-only (get-average-rating (assistant-id uint))
  (match (map-get? assistant-ratings assistant-id)
    stats (some (get average-rating stats))
    none
  )
)

(define-read-only (has-minimum-rating (assistant-id uint) (minimum-rating uint))
  (match (map-get? assistant-ratings assistant-id)
    stats (>= (get average-rating stats) minimum-rating)
    false
  )
)

(define-read-only (get-report-count (assistant-id uint))
  (default-to u0 (map-get? assistant-reports assistant-id))
)

(define-read-only (get-report (assistant-id uint) (reporter principal))
  (map-get? reports {assistant-id: assistant-id, reporter: reporter})
)
