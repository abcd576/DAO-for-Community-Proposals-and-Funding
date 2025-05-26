// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title CommunityDAO - DEBUGGED VERSION
 * @dev A decentralized autonomous organization for community proposals and funding
 * @author Community DAO Team
 * 
 * DEBUG FIXES APPLIED:
 * 1. Fixed getTotalVotingPower() to properly calculate actual voting power
 * 2. Added member address tracking for proper iteration
 * 3. Enhanced security with reentrancy protection
 * 4. Fixed potential overflow issues
 * 5. Added proper error handling and validation
 * 6. Improved gas optimization
 * 7. Added pause functionality for emergency situations
 * 8. Fixed voting power assignment logic
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract CommunityDAO is ReentrancyGuard, Pausable {
    // State variables
    address public owner;
    uint256 public proposalCount;
    uint256 public memberCount;
    uint256 public constant VOTING_PERIOD = 7 days;
    uint256 public constant MIN_QUORUM = 30; // 30% minimum participation
    uint256 public constant MAX_VOTING_POWER = 1000; // Prevent excessive voting power
    uint256 public constant MIN_PROPOSAL_AMOUNT = 0.001 ether; // Minimum proposal amount
    
    // FIX: Track member addresses for proper iteration
    address[] public memberAddresses;
    
    // Structs
    struct Member {
        bool isActive;
        uint256 votingPower;
        uint256 joinedAt;
        uint256 stake; // FIX: Track actual stake amount
    }
    
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        uint256 fundingAmount;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 createdAt;
        uint256 votingEndTime;
        bool isActive;
        bool isExecuted;
        mapping(address => bool) hasVoted;
    }
    
    // Mappings
    mapping(address => Member) public members;
    mapping(uint256 => Proposal) public proposals;
    mapping(address => uint256[]) public memberProposals;
    
    // FIX: Add member index mapping for efficient removal
    mapping(address => uint256) private memberIndex;
    
    // Events
    event MemberJoined(address indexed member, uint256 votingPower, uint256 stake);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string title, uint256 fundingAmount);
    event VoteCasted(uint256 indexed proposalId, address indexed voter, bool support, uint256 votingPower);
    event ProposalExecuted(uint256 indexed proposalId, bool approved, uint256 fundingAmount);
    event FundsDeposited(address indexed depositor, uint256 amount);
    event MemberLeft(address indexed member, uint256 stakeReturned);
    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);
    
    // Modifiers
    modifier onlyMember() {
        require(members[msg.sender].isActive, "Not an active member");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not the contract owner");
        _;
    }
    
    modifier proposalExists(uint256 _proposalId) {
        require(_proposalId > 0 && _proposalId <= proposalCount, "Proposal does not exist");
        _;
    }
    
    modifier votingActive(uint256 _proposalId) {
        require(proposals[_proposalId].isActive, "Proposal is not active");
        require(block.timestamp <= proposals[_proposalId].votingEndTime, "Voting period has ended");
        _;
    }
    
    // FIX: Add validation for reasonable amounts to prevent overflow
    modifier validAmount(uint256 _amount) {
        require(_amount > 0, "Amount must be greater than 0");
        require(_amount <= 1000000 ether, "Amount too large"); // Reasonable upper limit
        _;
    }
    
    // Constructor
    constructor() {
        owner = msg.sender;
        // FIX: Properly initialize owner as first member
        members[msg.sender] = Member({
            isActive: true,
            votingPower: 100,
            joinedAt: block.timestamp,
            stake: 0 // Owner doesn't need to stake
        });
        memberAddresses.push(msg.sender);
        memberIndex[msg.sender] = 0;
        memberCount = 1;
    }
    
    // Core Function 1: Join DAO as a member - FIXED
    /**
     * @dev Allows new members to join the DAO
     * FIX: Voting power now calculated based on stake, not arbitrary input
     */
    function joinDAO() external payable nonReentrant whenNotPaused {
        require(!members[msg.sender].isActive, "Already a member");
        require(msg.value >= 0.01 ether, "Minimum stake of 0.01 ETH required");
        
        // FIX: Calculate voting power based on stake (1 ETH = 100 voting power)
        uint256 calculatedVotingPower = (msg.value * 100) / 1 ether;
        if (calculatedVotingPower == 0) calculatedVotingPower = 1; // Minimum 1 voting power
        if (calculatedVotingPower > MAX_VOTING_POWER) calculatedVotingPower = MAX_VOTING_POWER;
        
        members[msg.sender] = Member({
            isActive: true,
            votingPower: calculatedVotingPower,
            joinedAt: block.timestamp,
            stake: msg.value
        });
        
        // FIX: Properly track member addresses
        memberAddresses.push(msg.sender);
        memberIndex[msg.sender] = memberAddresses.length - 1;
        memberCount++;
        
        emit MemberJoined(msg.sender, calculatedVotingPower, msg.value);
    }
    
    // FIX: Add function to leave DAO and get stake back
    function leaveDAO() external nonReentrant onlyMember {
        Member storage member = members[msg.sender];
        uint256 stakeToReturn = member.stake;
        
        // Mark member as inactive
        member.isActive = false;
        
        // Remove from member addresses array (swap with last element)
        uint256 indexToRemove = memberIndex[msg.sender];
        uint256 lastIndex = memberAddresses.length - 1;
        
        if (indexToRemove != lastIndex) {
            address lastMember = memberAddresses[lastIndex];
            memberAddresses[indexToRemove] = lastMember;
            memberIndex[lastMember] = indexToRemove;
        }
        
        memberAddresses.pop();
        delete memberIndex[msg.sender];
        memberCount--;
        
        // Return stake
        if (stakeToReturn > 0) {
            payable(msg.sender).transfer(stakeToReturn);
        }
        
        emit MemberLeft(msg.sender, stakeToReturn);
    }
    
    // Core Function 2: Create a proposal for funding - FIXED
    /**
     * @dev Allows DAO members to create funding proposals
     */
    function createProposal(
        string memory _title,
        string memory _description,
        uint256 _fundingAmount
    ) external onlyMember nonReentrant whenNotPaused validAmount(_fundingAmount) {
        require(bytes(_title).length > 0 && bytes(_title).length <= 100, "Title must be 1-100 characters");
        require(bytes(_description).length > 0 && bytes(_description).length <= 1000, "Description must be 1-1000 characters");
        require(_fundingAmount >= MIN_PROPOSAL_AMOUNT, "Funding amount too small");
        require(_fundingAmount <= address(this).balance, "Insufficient DAO funds");
        
        proposalCount++;
        
        Proposal storage newProposal = proposals[proposalCount];
        newProposal.id = proposalCount;
        newProposal.proposer = msg.sender;
        newProposal.title = _title;
        newProposal.description = _description;
        newProposal.fundingAmount = _fundingAmount;
        newProposal.createdAt = block.timestamp;
        newProposal.votingEndTime = block.timestamp + VOTING_PERIOD;
        newProposal.isActive = true;
        newProposal.isExecuted = false;
        
        memberProposals[msg.sender].push(proposalCount);
        
        emit ProposalCreated(proposalCount, msg.sender, _title, _fundingAmount);
    }
    
    // Core Function 3: Vote on proposals - FIXED
    /**
     * @dev Allows DAO members to vote on active proposals
     */
    function voteOnProposal(uint256 _proposalId, bool _support) 
        external 
        onlyMember 
        proposalExists(_proposalId) 
        votingActive(_proposalId)
        nonReentrant
        whenNotPaused
    {
        Proposal storage proposal = proposals[_proposalId];
        require(!proposal.hasVoted[msg.sender], "Already voted on this proposal");
        
        uint256 voterPower = members[msg.sender].votingPower;
        proposal.hasVoted[msg.sender] = true;
        
        // FIX: Use unchecked for gas optimization where overflow is impossible
        unchecked {
            if (_support) {
                proposal.votesFor += voterPower;
            } else {
                proposal.votesAgainst += voterPower;
            }
        }
        
        emit VoteCasted(_proposalId, msg.sender, _support, voterPower);
    }
    
    // Execute proposal after voting period - FIXED
    /**
     * @dev Executes a proposal after the voting period has ended
     */
    function executeProposal(uint256 _proposalId) 
        external 
        proposalExists(_proposalId)
        nonReentrant
        whenNotPaused
    {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp > proposal.votingEndTime, "Voting period still active");
        require(!proposal.isExecuted, "Proposal already executed");
        require(proposal.isActive, "Proposal is not active");
        
        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst;
        uint256 totalVotingPower = getTotalVotingPower();
        
        // FIX: Prevent division by zero
        require(totalVotingPower > 0, "No voting power available");
        
        // Check if minimum quorum is met
        bool quorumMet = (totalVotes * 100) >= (totalVotingPower * MIN_QUORUM);
        bool approved = quorumMet && (proposal.votesFor > proposal.votesAgainst);
        
        proposal.isExecuted = true;
        proposal.isActive = false;
        
        if (approved && address(this).balance >= proposal.fundingAmount) {
            // FIX: Use call instead of transfer for better gas handling
            (bool success, ) = payable(proposal.proposer).call{value: proposal.fundingAmount}("");
            require(success, "Transfer failed");
        }
        
        emit ProposalExecuted(_proposalId, approved, approved ? proposal.fundingAmount : 0);
    }
    
    // Helper functions - FIXED
    
    /**
     * @dev Calculates total voting power of all active members - FIXED
     * @return Total voting power
     */
    function getTotalVotingPower() public view returns (uint256) {
        uint256 totalPower = 0;
        
        // FIX: Properly iterate through all members
        for (uint256 i = 0; i < memberAddresses.length; i++) {
            address memberAddr = memberAddresses[i];
            if (members[memberAddr].isActive) {
                totalPower += members[memberAddr].votingPower;
            }
        }
        
        return totalPower;
    }
    
    /**
     * @dev Get all active members - NEW FUNCTION
     * @return Array of active member addresses
     */
    function getActiveMembers() external view returns (address[] memory) {
        address[] memory activeMembers = new address[](memberCount);
        uint256 activeCount = 0;
        
        for (uint256 i = 0; i < memberAddresses.length; i++) {
            if (members[memberAddresses[i]].isActive) {
                activeMembers[activeCount] = memberAddresses[i];
                activeCount++;
            }
        }
        
        // Resize array to actual active count
        assembly {
            mstore(activeMembers, activeCount)
        }
        
        return activeMembers;
    }
    
    /**
     * @dev Get proposal details - ENHANCED
     */
    function getProposal(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId) 
        returns (
            address proposer,
            string memory title,
            string memory description,
            uint256 fundingAmount,
            uint256 votesFor,
            uint256 votesAgainst,
            uint256 votingEndTime,
            bool isActive,
            bool isExecuted,
            uint256 totalVotes,
            bool quorumMet
        ) 
    {
        Proposal storage proposal = proposals[_proposalId];
        uint256 totalVotesCast = proposal.votesFor + proposal.votesAgainst;
        uint256 totalPower = getTotalVotingPower();
        bool quorum = totalPower > 0 && (totalVotesCast * 100) >= (totalPower * MIN_QUORUM);
        
        return (
            proposal.proposer,
            proposal.title,
            proposal.description,
            proposal.fundingAmount,
            proposal.votesFor,
            proposal.votesAgainst,
            proposal.votingEndTime,
            proposal.isActive,
            proposal.isExecuted,
            totalVotesCast,
            quorum
        );
    }
    
    /**
     * @dev Get member details - NEW FUNCTION
     */
    function getMemberDetails(address _member) external view returns (
        bool isActive,
        uint256 votingPower,
        uint256 joinedAt,
        uint256 stake,
        uint256[] memory proposalIds
    ) {
        Member storage member = members[_member];
        return (
            member.isActive,
            member.votingPower,
            member.joinedAt,
            member.stake,
            memberProposals[_member]
        );
    }
    
    /**
     * @dev Get member's proposal IDs
     */
    function getMemberProposals(address _member) external view returns (uint256[] memory) {
        return memberProposals[_member];
    }
    
    /**
     * @dev Deposit funds to the DAO treasury - ENHANCED
     */
    function depositFunds() external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "Must deposit some ether");
        emit FundsDeposited(msg.sender, msg.value);
    }
    
    /**
     * @dev Get DAO treasury balance
     */
    function getDAOBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    /**
     * @dev Emergency function to withdraw funds (only owner) - ENHANCED
     */
    function emergencyWithdraw(uint256 _amount) external onlyOwner nonReentrant {
        require(_amount <= address(this).balance, "Insufficient balance");
        
        (bool success, ) = payable(owner).call{value: _amount}("");
        require(success, "Emergency withdrawal failed");
    }
    
    /**
     * @dev Emergency pause function (only owner) - NEW
     */
    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyPaused(msg.sender);
    }
    
    /**
     * @dev Emergency unpause function (only owner) - NEW
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }
    
    /**
     * @dev Check if an address has voted on a proposal - NEW FUNCTION
     */
    function hasVotedOnProposal(uint256 _proposalId, address _voter) 
        external 
        view 
        proposalExists(_proposalId) 
        returns (bool) 
    {
        return proposals[_proposalId].hasVoted[_voter];
    }
    
    /**
     * @dev Get voting statistics for a proposal - NEW FUNCTION
     */
    function getProposalVotingStats(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId) 
        returns (
            uint256 votesFor,
            uint256 votesAgainst,
            uint256 totalVotes,
            uint256 totalPossibleVotes,
            uint256 participationRate,
            bool quorumMet
        ) 
    {
        Proposal storage proposal = proposals[_proposalId];
        uint256 totalVotesCast = proposal.votesFor + proposal.votesAgainst;
        uint256 totalPower = getTotalVotingPower();
        uint256 participation = totalPower > 0 ? (totalVotesCast * 100) / totalPower : 0;
        bool quorum = participation >= MIN_QUORUM;
        
        return (
            proposal.votesFor,
            proposal.votesAgainst,
            totalVotesCast,
            totalPower,
            participation,
            quorum
        );
    }
    
    // Receive function to accept direct ether transfers - ENHANCED
    receive() external payable {
        if (msg.value > 0) {
            emit FundsDeposited(msg.sender, msg.value);
        }
    }
    
    // FIX: Add fallback function for safety
    fallback() external payable {
        revert("Function not found");
    }
}

/*
=== MAJOR DEBUG FIXES APPLIED ===

1. **Fixed getTotalVotingPower()**: Now properly iterates through all members instead of using arbitrary calculation
2. **Added Member Tracking**: Implemented memberAddresses array to track all members for proper iteration
3. **Enhanced Security**: Added ReentrancyGuard and Pausable for better security
4. **Fixed Voting Power Logic**: Voting power now calculated based on stake amount, not user input
5. **Added Member Management**: Members can now leave DAO and get their stake back
6. **Improved Error Handling**: Added comprehensive validation and error messages
7. **Gas Optimization**: Used unchecked blocks where overflow is impossible
8. **Enhanced Transfer Logic**: Replaced transfer() with call() for better gas handling
9. **Added Emergency Controls**: Pause/unpause functionality for emergency situations
10. **Comprehensive View Functions**: Added functions to get detailed member and proposal information
11. **Fixed Array Management**: Proper addition/removal of members from tracking arrays
12. **Added Input Validation**: Reasonable limits on amounts and string lengths
13. **Enhanced Events**: More detailed event emissions for better tracking
14. **Fallback Protection**: Added fallback function to prevent accidental calls

=== REMAINING CONSIDERATIONS ===

1. Consider upgradeability pattern (proxy contracts)
2. Add time-based voting power decay
3. Implement proposal categories
4. Add proposal amendment functionality
5. Consider gas optimization for large member sets
6. Add integration tests for all edge cases
*/
