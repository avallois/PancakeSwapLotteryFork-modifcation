pragma solidity ^0.8.0;

import "./Context.sol";
import "./Ownable.sol";
import "./SafeMath.sol";//Not very useful here for sol > 8

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        //On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        //Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        //By storing the original value once again, a refund is triggered (see
        //https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

contract MyLottery is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    //address public injectorAddress;
    // address public operatorAddress;
    // address public treasuryAddress;

    uint256 public currentLotteryId;
    uint256 public currentTicketId;
    uint256 public maxNumberTicketsPerBuyOrClaim = 20;

    uint256 public lotteryPriceTicket;
    uint256 public lotteryTargetPot;
    uint256[5] public lotteryRewardsPerBracket;
    // uint256 public maxPriceTicketInCake = 50 ether;
    // uint256 public minPriceTicketInCake = 0.005 ether;

    // IRandomNumberGenerator public randomGenerator;

    enum Status {
        Pause,
        Open,
        Close,
        Claimable
    }

    struct Lottery {
        Status status;
        uint256 startTime;
        uint256 endTime;
        uint256 priceTicket;
        uint256 targetPot;
        uint256 currentPot;
        uint256[5] rewardsPerBracket; // 0: 1 matching number // 4: 5 matching numbers
        uint256[5] bnbPerBracketPerWinner;
        uint256[5] countWinnersPerBracket;
        uint256 firstTicketId;
        uint256 firstTicketIdNextLottery;
        uint32 finalNumber;
    }

    struct Ticket {
        uint32 number;
        address owner;
    }

    event LotteryOpen(
        uint256 indexed lotteryId,
        uint256 startTime,
        uint256 priceTicket,
        uint256 firstTicketId
    );

    event LotteryClose(uint256 indexed lotteryId, uint256 firstTicketIdNextLottery);
    event LotteryNumberDrawn(uint256 indexed lotteryId, uint256 finalNumber, uint256 countWinningTickets);
    event TicketsClaim(address indexed claimer, uint256 amount, uint256 indexed lotteryId, uint256 numberTickets);
    event TicketsPurchase(address indexed buyer, uint256 indexed lotteryId, uint256 numberTickets);

    // Mapping are cheaper than arrays
    mapping(uint256 => Lottery) private _lotteries;
    mapping(uint256 => Ticket) private _tickets;

    // Bracket calculator is used for verifying claims for ticket prizes
    mapping(uint32 => uint32) private _bracketCalculator;

    // Keeps track of number of ticket per unique combination for each lotteryId
    mapping(uint256 => mapping(uint32 => uint256)) private _numberTicketsPerLotteryId;

    // Keep track of user ticket ids for a given lotteryId
    mapping(address => mapping(uint256 => uint256[])) private _userTicketIdsPerLotteryId;
    
    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    constructor(uint256 _priceTicket, uint256 _targetPot, uint256[5] memory _rewardsPerBracket) {
    // constructor(address _randomGeneratorAddress) {
        //ATTENTION on va en avoir besoin
        // randomGenerator = IRandomNumberGenerator(_randomGeneratorAddress);
        lotteryPriceTicket = _priceTicket;
        lotteryTargetPot =  _targetPot;
        lotteryRewardsPerBracket = _rewardsPerBracket;
        // Initializes a mapping
        _bracketCalculator[0] = 1;
        _bracketCalculator[1] = 11;
        _bracketCalculator[2] = 111;
        _bracketCalculator[3] = 1111;
        _bracketCalculator[4] = 11111;

        startLottery(_priceTicket, _targetPot, _rewardsPerBracket);
    }

    function buyTickets(uint256 _lotteryId, uint32[] calldata _ticketNumbers)
        external
        payable
        nonReentrant
        notContract
    {
        require(_lotteries[_lotteryId].status == Status.Open, "Lottery is not open");
        require(_ticketNumbers.length != 0, "No ticket specified");
        require((_lotteries[_lotteryId].priceTicket * _ticketNumbers.length) <= (_lotteries[_lotteryId].targetPot - _lotteries[_lotteryId].currentPot), "Not enough tickets left");   
        require(msg.value == _lotteries[_lotteryId].priceTicket * _ticketNumbers.length, "Payment amount is wrong");   
        require(_ticketNumbers.length <= maxNumberTicketsPerBuyOrClaim, "Too many tickets");

        if (_lotteries[currentLotteryId].currentPot == 0) {
            drawFinalNumberAndMakeLotteryClaimable(currentLotteryId - 1);
        }


        for (uint256 i = 0; i < _ticketNumbers.length; i++) {
            uint32 thisTicketNumber = _ticketNumbers[i];

            require((thisTicketNumber >= 100000) && (thisTicketNumber <= 199999), "Outside range");//le numéro de ticket doit etre valide
            //on peut pas faire 00000 à 99999 car octal number are not allowed (001, 002 etc)
            //     and aussi on veut les stocker en nombre car c'est moins couteux

            _numberTicketsPerLotteryId[_lotteryId][1 + (thisTicketNumber % 10)]++;
            _numberTicketsPerLotteryId[_lotteryId][11 + (thisTicketNumber % 100)]++;//on ajoute 11 pcq on peut pas enregster la combinaison 01 sinon par exemple
            _numberTicketsPerLotteryId[_lotteryId][111 + (thisTicketNumber % 1000)]++;//on ajoute 11 pcq on peut pas enregster la combinaison 901 sinon par exemple
            _numberTicketsPerLotteryId[_lotteryId][1111 + (thisTicketNumber % 10000)]++;
            _numberTicketsPerLotteryId[_lotteryId][11111 + (thisTicketNumber % 100000)]++;

            _userTicketIdsPerLotteryId[msg.sender][_lotteryId].push(currentTicketId);

            _tickets[currentTicketId] = Ticket({number: thisTicketNumber, owner: msg.sender});

            currentTicketId++;
        }

        _lotteries[_lotteryId].currentPot += msg.value;

        if (_lotteries[_lotteryId].currentPot == _lotteries[_lotteryId].currentPot) {
            closeLottery(currentLotteryId);
            startLottery(lotteryPriceTicket, lotteryTargetPot, lotteryRewardsPerBracket);
        }

        emit TicketsPurchase(msg.sender, _lotteryId, _ticketNumbers.length);
    }

    function startLottery(   
        uint256 _priceTicket,
        uint256 _targetPot,
        uint256[5] memory _rewardsPerBracket
    ) private {

        require(_targetPot % _priceTicket == 0, "Pots and price not compatible");
        require(_targetPot / _priceTicket > maxNumberTicketsPerBuyOrClaim, "Not enough tickets available");

        require(
            _rewardsPerBracket[0] +
                _rewardsPerBracket[1] +
                _rewardsPerBracket[2] +
                _rewardsPerBracket[3] +
                _rewardsPerBracket[4] == _targetPot,
            "Rewards must equal targetPot"
        );

        currentLotteryId++;

        _lotteries[currentLotteryId] = Lottery({
            status: Status.Open,
            startTime: block.timestamp,
            endTime: 0,
            priceTicket: _priceTicket,
            targetPot: _targetPot,
            currentPot: 0,
            rewardsPerBracket: _rewardsPerBracket,
            bnbPerBracketPerWinner: [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)],
            countWinnersPerBracket: [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)],
            firstTicketId: currentTicketId,
            firstTicketIdNextLottery: currentTicketId,
            finalNumber: 0
        });

        emit LotteryOpen(
            currentLotteryId,
            block.timestamp,
            _priceTicket,
            currentTicketId
        );
    }

    function closeLottery(uint256 _lotteryId) private nonReentrant {
        require(_lotteries[_lotteryId].status == Status.Open, "Lottery not open");
        require(_lotteries[_lotteryId].currentPot == _lotteries[_lotteryId].targetPot, "Target pot not reached");
        // require(block.timestamp > _lotteries[_lotteryId].endTime, "Lottery not over");
        _lotteries[_lotteryId].firstTicketIdNextLottery = currentTicketId;

        // Request a random number from the generator based on a seed
        //ATTENTION: VRF chainlink
        // randomGenerator.getRandomNumber(uint256(keccak256(abi.encodePacked(_lotteryId, currentTicketId))));

        _lotteries[_lotteryId].endTime = block.timestamp;
        _lotteries[_lotteryId].status = Status.Close;

        emit LotteryClose(_lotteryId, currentTicketId);
    }

    function drawFinalNumberAndMakeLotteryClaimable(uint256 _lotteryId)
        private
    {
        require(_lotteries[_lotteryId].status == Status.Close, "Lottery not close");
        //ATTENTION ca sera necessaire au fonctionnement
        // require(_lotteryId == randomGenerator.viewLatestLotteryId(), "Numbers not drawn");

        // Calculate the finalNumber based on the randomResult generated by ChainLink's fallback
        //ATTENTION il faudra recup le final number de cette manière !
        // uint32 finalNumber = randomGenerator.viewRandomResult();
        uint32 finalNumber = 199983;

        // Initialize a number to count addresses in the previous bracket
        uint256 numberAddressesInPreviousBracket;

        // Initializes the amount to withdraw to treasury
        // uint256 amountToWithdrawToTreasury;

        uint256 amountNotWon;

        // Calculate prizes in CAKE for each bracket by starting from the highest one
        for (uint32 i = 0; i < 5; i++) {
            uint32 j = 4 - i;
            uint32 transformedWinningNumber = _bracketCalculator[j] + (finalNumber % (uint32(10)**(j + 1)));

            _lotteries[_lotteryId].countWinnersPerBracket[j] =
                _numberTicketsPerLotteryId[_lotteryId][transformedWinningNumber] -
                numberAddressesInPreviousBracket;

            // A. If number of users for this _bracket number is superior to 0
            //if there are winners that not won previous bracket
            if (
                (_numberTicketsPerLotteryId[_lotteryId][transformedWinningNumber] - numberAddressesInPreviousBracket) !=
                0
            ) {
                // B. If rewards at this bracket are > 0, calculate, else, report the numberAddresses from previous bracket
                //UPREWARD
                _lotteries[_lotteryId].bnbPerBracketPerWinner[j] = _lotteries[_lotteryId].rewardsPerBracket[j] /
                    (_numberTicketsPerLotteryId[_lotteryId][transformedWinningNumber] -
                        numberAddressesInPreviousBracket);
                    // Update numberAddressesInPreviousBracket
                numberAddressesInPreviousBracket = _numberTicketsPerLotteryId[_lotteryId][transformedWinningNumber];
                // A. No CAKE to distribute, they are added to the amount to withdraw to treasury address
            } else {
                _lotteries[_lotteryId].bnbPerBracketPerWinner[j] = 0;
                amountNotWon += _lotteries[_lotteryId].rewardsPerBracket[j];
                // amountToWithdrawToTreasury +=
                //     (_lotteries[_lotteryId].rewardsBreakdown[j] * amountToShareToWinners) /
                //     10000;
                //voir quand on corrigera les bails de decimal si ca nous sert
            }
        }

        // Update internal statuses for lottery
        _lotteries[_lotteryId].finalNumber = finalNumber;
        _lotteries[_lotteryId].status = Status.Claimable;

        // if (_autoInjection) {
        //     pendingInjectionNextLottery = amountToWithdrawToTreasury;
        //     amountToWithdrawToTreasury = 0;
        // }

        // amountToWithdrawToTreasury += (_lotteries[_lotteryId].amountCollectedInCake - amountToShareToWinners);

        payable(owner()).transfer(amountNotWon);

        emit LotteryNumberDrawn(currentLotteryId, finalNumber, numberAddressesInPreviousBracket);
    }
//lors de l'achat du dernier ticket il ne faut pas oublier de close la lottery
//                      pour que personne n'essaye d'acheter un nouveau ticket
    function claimTickets(
        uint256 _lotteryId,
        uint256[] calldata _ticketIds,
        uint32[] calldata _brackets
    ) external nonReentrant{
        //notContract nonReentrant
        require(_ticketIds.length == _brackets.length, "Not same length");
        require(_ticketIds.length != 0, "Length must be >0");
        require(_ticketIds.length <= maxNumberTicketsPerBuyOrClaim, "Too many tickets");
        require(_lotteries[_lotteryId].status == Status.Claimable, "Lottery not claimable");

        //Initializes the rewardInCakeToTransfer
        uint256 rewardInBnbToTransfer;

        for (uint256 i = 0; i < _ticketIds.length; i++) {
            require(_brackets[i] < 5, "Bracket out of range"); //Must be between 0 and 4

            uint256 thisTicketId = _ticketIds[i];

            require(_lotteries[_lotteryId].firstTicketIdNextLottery > thisTicketId, "TicketId too high");
            require(_lotteries[_lotteryId].firstTicketId <= thisTicketId, "TicketId too low");
            require(msg.sender == _tickets[thisTicketId].owner, "Not the owner");

            //Update the lottery ticket owner to 0x address
            _tickets[thisTicketId].owner = address(0);

            uint256 rewardForTicketId = _calculateRewardsForTicketId(_lotteryId, thisTicketId, _brackets[i]);

            //Check user is claiming the correct bracket
            require(rewardForTicketId != 0, "No prize for this bracket");

            if (_brackets[i] != 4) {
                require(
                    _calculateRewardsForTicketId(_lotteryId, thisTicketId, _brackets[i] + 1) == 0,
                    "Bracket must be higher"
                );
            }

            //Increment the reward to transfer
            rewardInBnbToTransfer += rewardForTicketId;
        }

        payable(msg.sender).transfer(rewardInBnbToTransfer);

        emit TicketsClaim(msg.sender, rewardInBnbToTransfer, _lotteryId, _ticketIds.length);
    }

    function _calculateRewardsForTicketId(
        uint256 _lotteryId,
        uint256 _ticketId,
        uint32 _bracket
    ) internal view returns (uint256) {
        // Retrieve the winning number combination
        uint32 userNumber = _lotteries[_lotteryId].finalNumber;

        // Retrieve the user number combination from the ticketId
        uint32 winningTicketNumber = _tickets[_ticketId].number;

        // Apply transformation to verify the claim provided by the user is true
        uint32 transformedWinningNumber = _bracketCalculator[_bracket] +
            (winningTicketNumber % (uint32(10)**(_bracket + 1)));

        uint32 transformedUserNumber = _bracketCalculator[_bracket] + (userNumber % (uint32(10)**(_bracket + 1)));

        // Confirm that the two transformed numbers are the same, if not throw
        if (transformedWinningNumber == transformedUserNumber) {
            return _lotteries[_lotteryId].bnbPerBracketPerWinner[_bracket];
        } else {
            return 0;
        }
    }

    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }
}

