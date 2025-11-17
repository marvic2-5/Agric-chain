#  AgriDAO  
### Decentralized Cooperative Farming DAO on Stacks (Clarity Smart Contract)

AgriDAO is a decentralized cooperative governance system built using **Clarity** on the  
**Stacks blockchain**. It enables farming communities and cooperatives to pool funds,  
vote on proposals, manage shared resources, and distribute profits fairly using  
transparent on-chain logic.

---

##  Features

### Member Management
- Register as a member by contributing STX  
- Add more contributions anytime  
- Withdraw part of your contribution  
- Indexed member list for easy frontend display  
- Owner can penalize members for misconduct  

---

### Proposal & Voting System
Members can create governance proposals such as:
- Buying farming equipment  
- Renting tractors  
- Bulk seed purchasing  
- Irrigation system upgrades  
- Community welfare projects  

Each proposal supports:
- Start & end block height  
- Votes "for" and "against"  
- Double-voting protection  
- Automatic fund release if approved  
- Majority voting rules  

---

###  Cooperative Profit Mechanism
- Anyone can deposit profits into the **profit pool**  
- Members claim profits proportional to their total contributions  
- Prevents double claiming  
- Real STX payouts directly from contract  

---

###  Admin / Owner Controls
- Penalize members (reassign contribution to profit pool)  
- Transfer ownership  
- Emergency withdrawal (failsafe)  

---

##  Tech Stack
- **Language:** Clarity  
- **Framework:** Clarinet  
- **Blockchain:** Stacks  
- **Contract Name:** `AgriDAO.clar`

---

##  Contract Structure

| Component | Purpose |
|----------|---------|
| `members` map | Tracks contributions, join date, and status |
| `proposals` map | Stores DAO proposals |
| `votes` map | Prevents double voting |
| `profit-pool` | STX available for distribution |
| `claimed-profits` | Tracks previous payouts |
| `owner` | Contract admin |
| `member-index` | Enables frontend pagination |

---

##  Key Functions

### Member Functions
- `register-member`
- `add-contribution`
- `withdraw-contribution`

### Proposal Governance
- `create-proposal`
- `vote-on-proposal`
- `finalize-proposal`

### Profit Sharing
- `deposit-profits`
- `claim-profit`

### Admin Functions
- `penalize-member`
- `change-owner`
- `owner-withdraw`

---

## How to Deploy (Clarinet)

```bash
clarinet new agri-dao
clarinet contract add contracts/AgriDAO.clar
clarinet check
clarinet test
