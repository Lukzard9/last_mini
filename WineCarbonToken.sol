// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract WineCarbonProtocol is ERC20, ERC20Burnable, AccessControl, ReentrancyGuard {
    
    // --- ROLES & CONFIG ---
    bytes32 public constant PRODUCER_ROLE = keccak256("PRODUCER_ROLE");
    bytes32 public constant JUDGE_ROLE = keccak256("JUDGE_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint256 public constant JUDGE_STAKE = 0.01 ether;
    uint256 public constant PRODUCER_BOND = 0.01 ether;
    uint256 public constant CHALLENGE_BOND = 0.02 ether;
    uint256 public constant CHALLENGE_WINDOW = 2 minutes; //72h
    
    uint256 public constant VOTE_QUORUM = 10; 
    uint256 public constant BASE_PRICE = 0.0001 ether;

    uint256 public globalCo2Threshold;

    enum Status { Pending, Verified, Rejected, Challenged, Finalized }

    struct Report {
        address producer;
        string ipfsHash;
        uint256 co2Emitted;
        uint256 threshold;
        Status status;
        Status originalStatus;
        uint256 submissionTime;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 challengeEndTime;
        address challenger;
        address[] voters; 
    }

    struct VoteInfo {
        bool hasVoted;
        bool support;
    }

    mapping(uint256 => Report) public reports;
    mapping(uint256 => mapping(address => VoteInfo)) public judgeVotes;
    mapping(address => uint256) public carbonDebt; 
    mapping(address => uint256) public reputation;
    
    uint256 public reportCount;

    // --- EVENTS ---
    event ReportSubmitted(uint256 indexed id, address producer, string ipfsHash);
    event Voted(uint256 indexed id, address judge, bool support, uint256 weight);
    event ChallengeRaised(uint256 indexed id, address challenger);
    event ReportFinalized(uint256 indexed id, Status status);
    event TokensPurchased(address buyer, uint256 amount, uint256 cost);
    event TokensSold(address seller, uint256 amount, uint256 payout);
    event JudgeSlashed(address judge, uint256 penalty);
    event JudgeRewarded(address judge, uint256 reward);

    constructor() ERC20("WineCarbon", "WINE") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
    }

    // --- 1. ACCESS CONTROL & STAKING ---

    function joinAsProducer() external payable nonReentrant {
        require(msg.value == PRODUCER_BOND, "Incorrect Bond");
        require(!hasRole(PRODUCER_ROLE, msg.sender), "Already a producer");
        require(!hasRole(JUDGE_ROLE, msg.sender), "Cannot be Judge and Producer"); 
        _grantRole(PRODUCER_ROLE, msg.sender);
    }

    function joinAsJudge() external payable nonReentrant {
        require(msg.value == JUDGE_STAKE, "Incorrect Stake");
        require(!hasRole(JUDGE_ROLE, msg.sender), "Already a judge");
        require(!hasRole(PRODUCER_ROLE, msg.sender), "Cannot be Producer and Judge");
        
        _grantRole(JUDGE_ROLE, msg.sender);
        reputation[msg.sender] = 20; 
    }

    // --- 2. DATA INPUT ---

    function setGlobalThreshold(uint256 _newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        globalCo2Threshold = _newThreshold;
    }

    function submitReport(uint256 _co2, string calldata _ipfsHash) external onlyRole(PRODUCER_ROLE) {
        require(carbonDebt[msg.sender] == 0, "Must settle carbon debt");

        reportCount++;
        Report storage newReport = reports[reportCount];
        newReport.producer = msg.sender;
        newReport.ipfsHash = _ipfsHash;
        newReport.co2Emitted = _co2;
        newReport.threshold = globalCo2Threshold;
        newReport.status = Status.Pending;
        newReport.submissionTime = block.timestamp;
        
        emit ReportSubmitted(reportCount, msg.sender, _ipfsHash);
    }

    // --- 3. VOTING (THE ECO-JUDGE) ---

    function vote(uint256 _id, bool _support) external onlyRole(JUDGE_ROLE) {
        Report storage r = reports[_id];
        require(r.status == Status.Pending, "Voting closed");
        require(r.voters.length < 20, "Max judges reached");
        require(!judgeVotes[_id][msg.sender].hasVoted, "Already voted");

        uint256 weight = reputation[msg.sender];
        if (weight == 0) weight = 1;

        if (_support) r.votesFor += weight;
        else r.votesAgainst += weight;

        judgeVotes[_id][msg.sender] = VoteInfo({hasVoted: true, support: _support});
        r.voters.push(msg.sender);

        emit Voted(_id, msg.sender, _support, weight);
    }

    function validateVoteResult(uint256 _id) external {
        Report storage r = reports[_id];
        require(r.status == Status.Pending, "Not pending");
        require(r.votesFor + r.votesAgainst >= VOTE_QUORUM, "Not enough votes yet");

        if (r.votesFor > r.votesAgainst) {
            r.status = Status.Verified;
        } else {
            r.status = Status.Rejected;
        }
        
        r.challengeEndTime = block.timestamp + CHALLENGE_WINDOW; 
    }

    // --- 4. DISPUTE MECHANISM ---

    function challengeReport(uint256 _id) external payable nonReentrant {
        Report storage r = reports[_id];
        require(r.status == Status.Verified || r.status == Status.Rejected, "Invalid status");
        require(block.timestamp < r.challengeEndTime, "Challenge window closed");
        require(msg.value >= CHALLENGE_BOND, "Insufficient bond");

        r.originalStatus = r.status; 
        
        r.status = Status.Challenged;
        r.challenger = msg.sender;
        emit ChallengeRaised(_id, msg.sender);
    }

    function resolveChallenge(uint256 _id, bool upholdOriginalDecision) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        Report storage r = reports[_id];
        require(r.status == Status.Challenged, "Not challenged");
        
        if (!upholdOriginalDecision) {
            // GOV AGREES WITH CHALLENGER (Judges were Wrong)
            payable(r.challenger).transfer(CHALLENGE_BOND);

            uint256 tokenReward = (CHALLENGE_BOND * 10**decimals()) / getBuyPrice();
            _mint(r.challenger, tokenReward);
            
            bool isVerifiedCorrect = (r.originalStatus == Status.Rejected);
            _slashWrongJudges(_id, isVerifiedCorrect);
        } else {
            isVerifiedCorrect = (r.originalStatus == Status.Verified);
        }

        r.status = Status.Finalized;
        
        if (isVerifiedCorrect) {
            _processEcoLogic(r);
        } else {
            _slashProducer(r.producer);
        }

        emit ReportFinalized(_id, r.status);
    }

    // --- 5. FINALIZATION (NO CHALLENGE) ---

    function finalize(uint256 _id) external nonReentrant {
        Report storage r = reports[_id];
        require(r.status == Status.Verified || r.status == Status.Rejected, "Status not finalizable");
        require(block.timestamp > r.challengeEndTime, "Challenge active");

        r.status = Status.Finalized;

        // Reward the Majority Voters (The ones who won without challenge)
        bool isVerified = (r.votesFor > r.votesAgainst);
        
        for (uint i = 0; i < r.voters.length; i++) {
            address judgeAddr = r.voters[i];
            bool judgeSupported = judgeVotes[_id][judgeAddr].support;
            
            // Only reward judges who aligned with the final outcome
            if (judgeSupported == isVerified) {
                reputation[judgeAddr] += 5;
                uint256 tokenReward = (0.2 * JUDGE_STAKE * 10**decimals()) / getBuyPrice();
                _mint(judgeAddr, tokenReward);
            } else {
                reputation[judgeAddr] -= 5;
            }
        }

        if (isVerified) {
            _processEcoLogic(r);
        } else {
            _slashProducer(r.producer);
        }
        
        emit ReportFinalized(_id, Status.Finalized);
    }

    // --- 6. BONDING CURVE & MARKET ---

    function getBuyPrice() public view returns (uint256) {
        if (totalSupply() == 0) return BASE_PRICE;
        return (address(this).balance * 10**decimals()) / totalSupply();
}

    function buyTokens() external onlyRole(PRODUCER_ROLE) payable nonReentrant {
        uint256 pricePerToken = getBuyPrice();
        require(msg.value >= pricePerToken, "Sent ETH too low");
        
        uint256 amountToMint = (msg.value * 10**decimals()) / pricePerToken;
        _mint(msg.sender, amountToMint);
        emit TokensPurchased(msg.sender, amountToMint, pricePerToken);
    }

    function sellTokens(uint256 amount) external onlyRole(PRODUCER_ROLE) nonReentrant {
        require(balanceOf(msg.sender) >= amount, "Insufficient tokens");
        
        uint256 spotPrice = getBuyPrice(); 
        uint256 payout = (amount * spotPrice) / 10**decimals();
        require(address(this).balance >= payout, "Contract Reserve low");

        _burn(msg.sender, amount);
        payable(msg.sender).transfer(payout);
        emit TokensSold(msg.sender, amount, payout);
    }

    function settleDebt(uint256 amount) external onlyRole(PRODUCER_ROLE) {
        require(carbonDebt[msg.sender] >= amount, "Amount exceeds debt");
        _burn(msg.sender, amount);
        carbonDebt[msg.sender] -= amount;
    }

    // --- HELPERS ---

    function _processEcoLogic(Report storage r) internal {
        if (r.co2Emitted <= r.threshold) {
            uint256 savings = r.threshold - r.co2Emitted;
            uint256 rewardAmount = savings * 10**decimals();
            if (rewardAmount > 0) _mint(r.producer, rewardAmount);
        } else {
            uint256 excess = r.co2Emitted - r.threshold;
            uint256 fineAmount = excess * 10**decimals();
            if (balanceOf(r.producer) >= fineAmount) _burn(r.producer, fineAmount);
            else carbonDebt[r.producer] += fineAmount;
        }
    }

    function _slashWrongJudges(uint256 _id, bool correctVoteWasYes) internal {
        Report storage r = reports[_id];
        for (uint i = 0; i < r.voters.length; i++) {
            address judge = r.voters[i];
            // If correct vote was YES, we slash NO voters. And vice versa.
            if (judgeVotes[_id][judge].support != correctVoteWasYes) {
                if (reputation[judge] <= 30) {
                    reputation[judge] = 0;
                } else {
                    reputation[judge] = reputation[judge] / 2;
                }
                emit JudgeSlashed(judge, reputation[judge]);
            }
        }
    }

    function _slashProducer(address _producer) internal {
        uint256 fineAmount = balanceOf(_producer) / 2;
        _burn(_producer, fineAmount);
    }
}