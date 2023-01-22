// SPDX-License-Identifier: MIT
/// @author: github.com/cliffoo
pragma solidity ^0.8.0;


import "./chainlink/ConfirmedOwner.sol";
import "./chainlink/VRFV2WrapperConsumerBase.sol";

// Based on: https://docs.chain.link/samples/VRF/VRFv2DirectFundingConsumer.sol
// LINK Faucet: https://faucets.chain.link

contract ChoresDrawV1 is VRFV2WrapperConsumerBase, ConfirmedOwner {
  /**
  ----------------------------------------
  Events
  ----------------------------------------
   */

  event RequestSent(uint256 requestId, uint32 numChores);
  event RequestFulfilled(uint256 requestId, uint256 drawIndex);

  /**
  ----------------------------------------
  Modifiers
  ----------------------------------------
   */

  modifier requestExists(uint256 _id) {
    require(requests[_id].linkPaid > 0, "Request not found");
    _;
  }
  modifier choreExists(uint256 _id) {
    require(_id < numChores, "Chore not found");
    _;
  }
  modifier memberExists(uint256 _id) {
    require(_id < numMembers, "Member not found");
    _;
  }
  modifier drawExists(uint256 _id) {
    require(_id < draws.length, "Draw not found");
    _;
  }
  modifier nonEmptyValue(string memory _value) {
    require((bytes(_value)).length > 0, "Empty value");
    _;
  }
  modifier memberNameDoesNotExist(string memory _value) {
    for (uint256 i = 0; i < numMembers; i++) {
      require(
        keccak256(abi.encodePacked(_value)) !=
          keccak256(abi.encodePacked(members[i].name)),
        "Name already exists"
      );
    }
    _;
  }
  modifier onlyOwnerOrMemberOwner(uint256 _memberId) {
    bool isOwner = msg.sender == owner();
    bool isMemberOwner = msg.sender == members[_memberId].owner;
    require(isOwner || isMemberOwner, "Not owner or member owner");
    _;
  }

  /**
  ----------------------------------------
  Structs and state variables
  ----------------------------------------
   */

  // VRF request
  struct Request {
    uint256 linkPaid;
    bool fulfilled;
    uint256 drawIndex;
  }
  uint256[] public requestIds;
  uint256 public lastRequestId;
  mapping(uint256 => Request) public requests; // Request id => Request status

  // VRF request params
  uint32 callbackGasLimit = 100000;
  uint16 requestConfirmations = 3;
  // Hard-coded addresses for Goerli
  // - LINK
  address linkAddress = 0x326C977E6efc84E512bB9C30f76E30c160eD06FB;
  // - VRF wrapper
  address wrapperAddress = 0x708701a1DfF4f478de54383E49a627eD4852C816;

  // Chore
  struct Chore {
    string label;
  }
  uint32 public numChores = 0;
  mapping(uint256 => Chore) public chores; // Chore id => Chore

  // Member
  struct Member {
    string name;
    address owner;
    mapping(uint256 => bool) chores; // Chore id => Participation in chore
  }
  uint256 public numMembers = 0;
  mapping(uint256 => Member) public members; // Member id => Member

  // Draw
  struct Draw {
    uint256 timestamp;
    uint256[] randomNumbers;
    uint256 numChores;
    uint256 numMembers;
    mapping(uint256 => Chore) chores;
    mapping(uint256 => Member) members;
  }
  uint256 public numDraws = 0;
  Draw[] public draws;

  // Draw interpretation
  // A given Draw can produce an array of n DrawInterpretation,
  // where n is the number of chores in Draw.
  struct DrawInterpretation {
    uint256 timestamp;
    uint256 randomNumber;
    string choreLabel;
    string selectedMember;
    string[] enlistedMembers;
    string[] delistedMembers;
  }

  /**
  ----------------------------------------
   */

  constructor()
    ConfirmedOwner(msg.sender)
    VRFV2WrapperConsumerBase(linkAddress, wrapperAddress)
  {}

  /**
  ----------------------------------------
  VRF and LINK functions
  ----------------------------------------
   */

  function withdrawLink() external onlyOwner {
    LinkTokenInterface link = LinkTokenInterface(linkAddress);
    require(
      link.transfer(msg.sender, link.balanceOf(address(this))),
      "Unable to transfer"
    );
  }

  function requestDraw() external onlyOwner returns (uint256 requestId) {
    requestId = requestRandomness(
      callbackGasLimit,
      requestConfirmations,
      numChores
    );
    requests[requestId] = Request({
      linkPaid: VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit),
      fulfilled: false,
      drawIndex: 2**256 - 1
    });
    requestIds.push(requestId);
    lastRequestId = requestId;
    emit RequestSent(requestId, numChores);
    return requestId;
  }

  function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords)
    internal
    override
    requestExists(_requestId)
  {
    // Update requests
    uint256 drawIndex = draws.length;
    requests[_requestId].fulfilled = true;
    requests[_requestId].drawIndex = drawIndex;

    // Update draws
    Draw storage draw = draws[drawIndex];
    // Copy members to draw
    for (uint256 i = 0; i < numMembers; i++) {
      draw.members[i].name = members[i].name;
      draw.members[i].owner = members[i].owner;
      for (uint256 j = 0; j < numChores; j++) {
        draw.members[i].chores[j] = members[i].chores[j];
      }
    }
    // Copy chores to draw
    for (uint256 i = 0; i < numChores; i++) {
      draw.chores[i].label = chores[i].label;
    }
    draw.numMembers = numMembers;
    draw.numChores = numChores;
    draw.randomNumbers = _randomWords;
    draw.timestamp = block.timestamp;

    numDraws++;
    emit RequestFulfilled(_requestId, drawIndex);
  }

  /**
  ----------------------------------------
  Interpretation function
  ----------------------------------------
   */

  function interpretDraw(uint256 _drawIndex)
    external
    view
    drawExists(_drawIndex)
    returns (DrawInterpretation[] memory interpretations)
  {
    // Unpack some draw data
    uint256[] memory drawRandomNumbers = draws[_drawIndex].randomNumbers;
    uint256 drawNumChores = draws[_drawIndex].numChores;
    uint256 drawNumMembers = draws[_drawIndex].numMembers;

    // For each chore
    for (uint256 i = 0; i < drawNumChores; i++) {
      DrawInterpretation memory interpretation = interpretations[i];
      uint256 choreRandomNumber = drawRandomNumbers[i];
      string[] memory enlistedMembers;
      string[] memory delistedMembers;
      uint256 enlistedCounter = 0;
      uint256 delistedCounter = 0;

      // For each member
      for (uint256 j = 0; j < drawNumMembers; j++) {
        string memory memberName = draws[_drawIndex].members[j].name;
        if (draws[_drawIndex].members[j].chores[i]) {
          enlistedMembers[enlistedCounter] = memberName;
          enlistedCounter++;
        } else {
          delistedMembers[delistedCounter] = memberName;
          delistedCounter++;
        }
      }

      interpretation.timestamp = draws[_drawIndex].timestamp;
      interpretation.randomNumber = choreRandomNumber;
      interpretation.choreLabel = draws[_drawIndex].chores[i].label;
      interpretation.selectedMember = enlistedMembers[
        choreRandomNumber % enlistedCounter
      ];
      interpretation.enlistedMembers = enlistedMembers;
      interpretation.delistedMembers = delistedMembers;
    }

    return interpretations;
  }

  /**
  ----------------------------------------
  Chore functions
  ----------------------------------------
   */

  function addChore(string memory _label)
    external
    onlyOwner
    returns (uint256 choreId)
  {
    choreId = numChores;
    chores[choreId] = Chore({label: _label});
    numChores++;
    return choreId;
  }

  function removeChore(uint256 _choreId)
    external
    choreExists(_choreId)
    onlyOwner
  {
    uint256 lastChoreId = numChores - 1;
    if (_choreId != lastChoreId) _copyLastChoreTo(_choreId);

    delete chores[lastChoreId];
    numChores--;

    for (uint256 i = 0; i < numMembers; i++) {
      members[i].chores[_choreId] = members[i].chores[lastChoreId];
      delete members[i].chores[lastChoreId];
    }
  }

  function _copyLastChoreTo(uint256 _choreId) private {
    Chore storage lastChore = chores[numChores - 1];
    Chore storage choreAtId = chores[_choreId];
    choreAtId.label = lastChore.label;
  }

  /**
  ----------------------------------------
  Member functions
  ----------------------------------------
   */
  function addMember(string memory _name) external returns (uint256 memberId) {
    return addMember(_name, address(0));
  }

  function addMember(string memory _name, address _memberOwner)
    public
    nonEmptyValue(_name)
    memberNameDoesNotExist(_name)
    onlyOwner
    returns (uint256 memberId)
  {
    memberId = numMembers;
    Member storage member = members[memberId];
    member.name = _name;
    member.owner = _memberOwner;
    numMembers++;
    return memberId;
  }

  function removeMember(uint256 _memberId)
    external
    memberExists(_memberId)
    onlyOwner
  {
    uint256 lastMemberId = numMembers - 1;
    if (_memberId != lastMemberId) _copyLastMemberTo(_memberId);

    delete members[lastMemberId];
    numMembers--;
  }

  function _copyLastMemberTo(uint256 _memberId) private {
    Member storage lastMember = members[numMembers - 1];
    Member storage memberAtId = members[_memberId];
    memberAtId.name = lastMember.name;
    memberAtId.owner = lastMember.owner;
    for (uint256 i = 0; i < numChores; i++) {
      memberAtId.chores[i] = lastMember.chores[i];
    }
  }

  function updateMemberOwner(uint256 _memberId, address _memberOwner)
    external
    memberExists(_memberId)
    onlyOwnerOrMemberOwner(_memberId)
  {
    members[_memberId].owner = _memberOwner;
  }

  function updateMemberName(uint256 _memberId, string memory _name)
    external
    memberExists(_memberId)
    onlyOwner
  {
    members[_memberId].name = _name;
  }

  /**
  ----------------------------------------
  Chore and member functions
  ----------------------------------------
   */

  function enlistMemberForChore(uint256 _memberId, uint256 _choreId)
    public
    choreExists(_choreId)
    memberExists(_memberId)
    onlyOwnerOrMemberOwner(_memberId)
  {
    members[_memberId].chores[_choreId] = true;
  }

  function delistMemberForChore(uint256 _memberId, uint256 _choreId)
    public
    choreExists(_choreId)
    memberExists(_memberId)
    onlyOwnerOrMemberOwner(_memberId)
  {
    members[_memberId].chores[_choreId] = false;
  }

  function enlistMemberForAllChores(uint256 _memberId)
    external
    memberExists(_memberId)
    onlyOwnerOrMemberOwner(_memberId)
  {
    for (uint256 i = 0; i < numChores; i++) enlistMemberForChore(_memberId, i);
  }

  function delistMemberForAllChores(uint256 _memberId)
    external
    memberExists(_memberId)
    onlyOwnerOrMemberOwner(_memberId)
  {
    for (uint256 i = 0; i < numChores; i++) delistMemberForChore(_memberId, i);
  }

  function enlistAllMembersForChore(uint256 _choreId)
    external
    choreExists(_choreId)
    onlyOwner
  {
    for (uint256 i = 0; i < numMembers; i++) enlistMemberForChore(i, _choreId);
  }

  function delistAllMembersForChore(uint256 _choreId)
    external
    choreExists(_choreId)
    onlyOwner
  {
    for (uint256 i = 0; i < numMembers; i++) delistMemberForChore(i, _choreId);
  }
}
