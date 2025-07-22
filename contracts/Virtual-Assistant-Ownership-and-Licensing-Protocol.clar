(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-assistant-not-found (err u102))
(define-constant err-insufficient-payment (err u103))
(define-constant err-license-expired (err u104))
(define-constant err-skill-not-found (err u105))
(define-constant err-invalid-royalty (err u106))

(define-non-fungible-token virtual-assistant uint)

(define-data-var next-assistant-id uint u1)
(define-data-var platform-fee-percentage uint u500)

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
    is-licensable: bool
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
        is-licensable: true
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
    (asserts! (get is-licensable assistant) err-not-authorized)
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

(define-public (use-assistant (assistant-id uint))
  (let
    (
      (assistant (unwrap! (map-get? assistants assistant-id) err-assistant-not-found))
      (license (unwrap! (map-get? licenses {assistant-id: assistant-id, licensee: tx-sender}) err-not-authorized))
    )
    (asserts! (> (get expires-at license) burn-block-height) err-license-expired)
    (asserts! (> (get remaining-usage license) u0) err-insufficient-payment)
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

(define-public (set-platform-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-fee u1000) err-invalid-royalty)
    (var-set platform-fee-percentage new-fee)
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
