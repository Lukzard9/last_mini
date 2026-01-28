// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract WineCarbonProtocol is
    ERC20,
    ERC20Burnable,
    AccessControl,
    ReentrancyGuard
{
    // --- ROLES & CONFIG ---
    bytes32 public constant PRODUCER_ROLE = keccak256("PRODUCER_ROLE");
    bytes32 public constant JUDGE_ROLE = keccak256("JUDGE_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint256 public constant JUDGE_STAKE = 0.01 ether;
    uint256 public constant PRODUCER_BOND = 0.01 ether;
    uint256 public constant CHALLENGE_BOND = 0.02 ether;
    uint256 public constant CHALLENGE_WINDOW = 2 minutes; //72h

    uint256 public constant VOTE_QUORUM = 50;
    uint256 public constant BASE_PRICE = 0.0001 ether;
    uint256 public constant PRICE_SLOPE = 0.000001 ether;
    uint256 public constant IMPROVEMENT_WEIGHT = 20;
    uint256 public constant TOLERANCE_WEIGHT = 5;

    uint256 public constant CO2_PER_ENERGY = 500; // e.g., 500g CO2 per kWh
    uint256 public constant CO2_PER_WATER = 10; // e.g., 10g CO2 per Liter
    uint256 public constant CO2_PER_CHEMICAL = 2000; // e.g., 2000g CO2 per kg of synthetic pesticide
    uint256 public constant CO2_PER_LOGISTICS = 100; // e.g., 100g CO2 per kg-km (weight * distance)

    uint256 public globalCo2Threshold = 1200; // Initial CO2 threshold in g/L

    enum Status {
        Pending,
        Verified,
        Rejected,
        Challenged,
        Finalized
    }

    struct Report {
        address producer;
        string ipfsHash;
        ProductionMetrics metrics;
        uint256 co2PerLiter;
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

    struct ProductionMetrics {
        uint256 wineProduced; // Amount of wine in Liters
        uint256 energyUsed; // Energy Consumption
        uint256 waterUsed; // Water Usage
        uint256 chemicalUsage; // Chemical Footprint
        uint256 logisticsScore; // Packaging & Logistics (Weight * Distance)
        uint256 sequestration; // Carbon Sequestration (Credit)
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
    event ReportSubmitted(
        uint256 indexed id,
        address producer,
        uint256 calculatedCo2,
        string ipfsHash
    );
    event Voted(
        uint256 indexed id,
        address judge,
        bool support,
        uint256 weight
    );
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
        require(
            !hasRole(JUDGE_ROLE, msg.sender),
            "Cannot be Judge and Producer"
        );
        _grantRole(PRODUCER_ROLE, msg.sender);
    }

    function joinAsJudge() external payable nonReentrant {
        require(msg.value == JUDGE_STAKE, "Incorrect Stake");
        require(!hasRole(JUDGE_ROLE, msg.sender), "Already a judge");
        require(
            !hasRole(PRODUCER_ROLE, msg.sender),
            "Cannot be Producer and Judge"
        );

        _grantRole(JUDGE_ROLE, msg.sender);
        reputation[msg.sender] = 20;
    }

    // --- 2. DATA INPUT ---

    function submitReport(
        ProductionMetrics calldata _metrics,
        string calldata _ipfsHash
    ) external onlyRole(PRODUCER_ROLE) {
        require(carbonDebt[msg.sender] == 0, "Must settle carbon debt");

        (Report memory newReport, uint256 co2PerLiter) = computeAndSetCO2(
            _metrics
        );

        newReport.producer = msg.sender;
        newReport.ipfsHash = _ipfsHash;
        newReport.threshold = globalCo2Threshold;
        newReport.status = Status.Pending;
        newReport.submissionTime = block.timestamp;

        emit ReportSubmitted(reportCount, msg.sender, co2PerLiter, _ipfsHash);
    }

    function computeAndSetCO2(
        ProductionMetrics calldata _metrics
    ) internal returns (Report memory, uint256) {
        require(_metrics.wineProduced > 0, "Production cannot be zero");
        uint256 grossEmissions = (_metrics.energyUsed * CO2_PER_ENERGY) +
            (_metrics.waterUsed * CO2_PER_WATER) +
            (_metrics.chemicalUsage * CO2_PER_CHEMICAL) +
            (_metrics.logisticsScore * CO2_PER_LOGISTICS);

        uint256 finalCo2;
        if (_metrics.sequestration >= grossEmissions) {
            finalCo2 = 0; // Carbon Neutral or Negative (Net Zero)
        } else {
            finalCo2 = grossEmissions - _metrics.sequestration;
        }

        uint256 co2PerLiter = finalCo2 / _metrics.wineProduced;

        reportCount++;
        Report storage newReport = reports[reportCount];
        ProductionMetrics memory newMetrics;
        newMetrics.energyUsed = _metrics.energyUsed;
        newMetrics.waterUsed = _metrics.waterUsed;
        newMetrics.chemicalUsage = _metrics.chemicalUsage;
        newMetrics.logisticsScore = _metrics.logisticsScore;
        newMetrics.sequestration = _metrics.sequestration;
        newReport.metrics = newMetrics;
        newReport.co2PerLiter = co2PerLiter;
        return (newReport, co2PerLiter);
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

        judgeVotes[_id][msg.sender] = VoteInfo({
            hasVoted: true,
            support: _support
        });
        r.voters.push(msg.sender);

        emit Voted(_id, msg.sender, _support, weight);
    }

    function validateVoteResult(uint256 _id) external {
        Report storage r = reports[_id];
        require(r.status == Status.Pending, "Not pending");
        require(
            r.votesFor + r.votesAgainst >= VOTE_QUORUM,
            "Not enough votes yet"
        );

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
        require(
            r.status == Status.Verified || r.status == Status.Rejected,
            "Invalid status"
        );
        require(
            block.timestamp < r.challengeEndTime,
            "Challenge window closed"
        );
        require(msg.value >= CHALLENGE_BOND, "Insufficient bond");

        r.originalStatus = r.status;

        r.status = Status.Challenged;
        r.challenger = msg.sender;
        emit ChallengeRaised(_id, msg.sender);
    }

    function resolveChallenge(
        uint256 _id,
        bool upholdOriginalDecision
    ) external onlyRole(GOVERNANCE_ROLE) nonReentrant {
        Report storage r = reports[_id];
        require(r.status == Status.Challenged, "Not challenged");
        bool isVerifiedCorrect;

        if (!upholdOriginalDecision) {
            // GOV AGREES WITH CHALLENGER (Judges were Wrong)
            payable(r.challenger).transfer(CHALLENGE_BOND);

            uint256 tokenReward = (CHALLENGE_BOND * 10 ** decimals()) /
                getBuyPrice();
            _mint(r.challenger, tokenReward);

            isVerifiedCorrect = (r.originalStatus == Status.Rejected);
            _slashWrongJudges(_id, isVerifiedCorrect);
        } else {
            isVerifiedCorrect = (r.originalStatus == Status.Verified);
        }

        r.status = Status.Finalized;

        if (isVerifiedCorrect) {
            _processEcoLogic(r);
            _updateGlobalThreshold(r.co2PerLiter);
        } else {
            _slashProducer(r.producer);
        }

        emit ReportFinalized(_id, r.status);
    }

    // --- 5. FINALIZATION (NO CHALLENGE) ---

    function finalize(uint256 _id) external nonReentrant {
        Report storage r = reports[_id];
        require(
            r.status == Status.Verified || r.status == Status.Rejected,
            "Status not finalizable"
        );
        require(block.timestamp > r.challengeEndTime, "Challenge active");

        r.status = Status.Finalized;

        // Reward the Majority Voters (The ones who won without challenge)
        bool isVerified = (r.votesFor > r.votesAgainst);
        uint256 tokenReward = (JUDGE_STAKE / 5 * 10 ** decimals()) /getBuyPrice();

        for (uint i = 0; i < r.voters.length; i++) {
            address judgeAddr = r.voters[i];
            bool judgeSupported = judgeVotes[_id][judgeAddr].support;

            if (judgeSupported == isVerified) {
                reputation[judgeAddr] += 5;
                _mint(judgeAddr, tokenReward);
            } else {
                if (reputation[judgeAddr] > 5) {
                    reputation[judgeAddr] -= 5;
                } else {
                    reputation[judgeAddr] = 0;
                }
            }
        }

        if (isVerified) {
            _processEcoLogic(r);
            _updateGlobalThreshold(r.co2PerLiter);
        } else {
            _slashProducer(r.producer);
        }

        emit ReportFinalized(_id, Status.Finalized);
    }

    // --- 6. BONDING CURVE & MARKET ---

    function getBuyPrice() public view returns (uint256) {
        return BASE_PRICE + (totalSupply() * PRICE_SLOPE); 
    }

    function buyTokens() external payable onlyRole(PRODUCER_ROLE) nonReentrant {
        uint256 pricePerToken = getBuyPrice();
        require(msg.value >= pricePerToken, "Sent ETH too low");

        uint256 amountToMint = (msg.value * 10 ** decimals()) / pricePerToken;
        _mint(msg.sender, amountToMint);
        emit TokensPurchased(msg.sender, amountToMint, pricePerToken);
    }

    function sellTokens(
        uint256 amount
    ) external onlyRole(PRODUCER_ROLE) nonReentrant {
        require(balanceOf(msg.sender) >= amount, "Insufficient tokens");

        uint256 spotPrice = getBuyPrice();
        uint256 payout = (amount * spotPrice) / 10 ** decimals();
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
        if (r.co2PerLiter <= r.threshold) {
            uint256 savings = r.threshold - r.co2PerLiter;
            uint256 rewardAmount = savings * 10 ** decimals();
            if (rewardAmount > 0) _mint(r.producer, rewardAmount);
        } else {
            uint256 excess = r.co2PerLiter - r.threshold;
            uint256 fineAmount = excess * 10 ** decimals();
            if (balanceOf(r.producer) >= fineAmount)
                _burn(r.producer, fineAmount);
            else carbonDebt[r.producer] += fineAmount;
        }
    }

    function _updateGlobalThreshold(uint256 _newVerifiedCo2) internal {
        if (_newVerifiedCo2 < globalCo2Threshold) {
            uint256 diff = globalCo2Threshold - _newVerifiedCo2;
            uint256 change = (diff * IMPROVEMENT_WEIGHT) / 100;
            globalCo2Threshold -= change;
        } else {
            uint256 diff = _newVerifiedCo2 - globalCo2Threshold;
            uint256 change = (diff * TOLERANCE_WEIGHT) / 100;
            globalCo2Threshold += change;
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
