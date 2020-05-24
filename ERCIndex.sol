pragma solidity ^0.6.0;

// "SPDX-License-Identifier: UNLICENSED"

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol";

import "./2_Owner.sol";

interface MyUniswapProxy {
    function calculateIndexValueAndNextTokenIndex(uint numberOfTokens) external returns(uint, uint);
    function executeSwap(ERC20 srcToken, uint srcQty, ERC20 destToken, address destAddress) external;
}

contract ERCIndex is ERC20, Owner {
    
    // Variables
    
    ERC20[] public topTokens;
    //ERC20 daiToken = ERC20(0xaD6D458402F60fD3Bd25163575031ACDce07538D); // ropsten
    //ERC20 daiToken = ERC20(0x2448eE2641d78CC42D7AD76498917359D961A783); // rinkeby
    ERC20 daiToken = ERC20(	0x6B175474E89094C44Da98b954EedeAC495271d0F); // mainnet
    
    MyUniswapProxy public myUniswapProxy;
    
    bool public isActive = true;

    // Functions
        
    constructor(address _myProxyAddress) public ERC20("ERC Index", "ERCI") {
        
        _mint(msg.sender, 0);
        
        myUniswapProxy = MyUniswapProxy(_myProxyAddress);
        
        daiToken.approve(address(myUniswapProxy), 2 ** 256 - 1);
    
    }
    
    // add address of ERC20 token to top token regitry
    function addNextTopToken(ERC20 _token) public isOwner {
        // ropsten addresses:
        // DAI 0xaD6D458402F60fD3Bd25163575031ACDce07538D
        // BAT 0xDb0040451F373949A4Be60dcd7b6B8D6E42658B6
        // MKR 0x4a47be893ddef62696800ffcddb8476c92ab4221
        // LINK 0xb4f7332ed719Eb4839f091EDDB2A3bA309739521 -
        // OMG 0x4BFBa4a8F28755Cb2061c413459EE562c6B9c51b -
        // KNC 0x7b2810576aa1cce68f2b118cef1f36467c648f92 -
        
        // wont have more than 10 ERC20 tokens - keeping gas costs low
        require(topTokensLength() < 10);
        
        topTokens.push(_token);
        
        _token.approve(address(myUniswapProxy), (2 ** 256) - 1);
    }
    
    // remove address of ERC20 token to top token regitry & sell it for DAI
    function removeTopTopen(uint _index) public isOwner {
        
        require(_index >= 0 && _index < topTokensLength()); 
        
        _sellERCToken(topTokens[_index], topTokens[_index].balanceOf(address(this)), address(this)); // sell token for dai
        
        topTokens[_index] = topTokens[topTokensLength() - 1]; // remove token from top tokens (ovverride with token in last place)
        
        topTokens.pop(); // remove last token from array
        
    }
    
    function topTokensLength() public view returns (uint) {
        
        return topTokens.length;
        
    }
    
    // helper function used by myUniswapProxy contract
    function getTokenAddressAndBalance(uint _index) public view returns (ERC20, uint) {
        
        require (_index < topTokensLength());
        
        return (topTokens[_index], topTokens[_index].balanceOf(address(this)));
        
    }
    
    /*
        Call this function to purchase ERCI with DAI (must set dai allowance beforehand)
        The index will buy the appropriate token from its registry and mint the sender their share of ERCI
    */
    function buyERCIWithDai(uint256 _daiAmount) public returns(bool) {
    
        require(isActive, "Contract was shut down!");
        require(_daiAmount > 0);
        require(daiToken.transferFrom(msg.sender, address(this), _daiAmount));
        
        require(topTokensLength() > 0);
        
        uint daiValue;
        
        uint index;
        
        // claculate dai value of ERCI index and the next token that should be purchased
        (daiValue, index) = myUniswapProxy.calculateIndexValueAndNextTokenIndex(topTokensLength());
        
        // number of ERCI to grant sender
        // ! daiValue will include the current dai deposit
        uint mintAmount = getMintAmount(_daiAmount, daiValue);
        
        _buyERCToken(daiToken.balanceOf(address(this)), topTokens[index]); // buy token with both sender's dai and contract's dai
        
        _mint(msg.sender, mintAmount);
    }
    
    // Calculate fair share of ERCI tokens
    // note - _totalDaiValue is always >= _addAmount
    function getMintAmount(uint _addAmount, uint _totalDaiValue) public view returns(uint) {
        
        uint previousDaiValue = _totalDaiValue - _addAmount;
        
        if (previousDaiValue == 0) {
            
            return _addAmount; // will do 1:1 in this case
            
        } else {
            
            return (totalSupply() * _addAmount) / previousDaiValue; // return proportional value of index
            
        }
        
    }
    
    function _buyERCToken(uint _daiAmount, ERC20 _token) private {
        
        myUniswapProxy.executeSwap(daiToken, _daiAmount, _token, address(this));
        
    }

    // call this function to sell ERCI tokens and claim your share of DAI from the fund
    function sellERCIforDai(uint _erciAmount) public {
        
        require(_erciAmount > 0 , "Amount too low");
        require(_erciAmount <= balanceOf(msg.sender), "Insufficient funds");
        require(_erciAmount <= allowance(msg.sender, address(this)), "ERCI allowance not set");
        require(ERC20(this).transferFrom(msg.sender, address(this), _erciAmount));
        
        uint percent = getPercent(_erciAmount);
        
        _sellPercentOfIndexForDai(percent, msg.sender);
        
        _claimDai(percent);
        
        _burn(address(this), _erciAmount);
        
    }
    
    // return the percent of ERCI that is being sold, multiplied by 10 ** 18
    function getPercent(uint _erciAmount) internal view returns(uint) {
        
        return (_erciAmount * (10 ** 18))  / totalSupply(); // instead of 0.125 return 125000000000000000
        
    }
    
    // will sell percent of each token and send DAI to _receiver
    function _sellPercentOfIndexForDai(uint _percent, address _receiver) internal {
        
        for (uint i = 0; i < topTokensLength(); i++) {
            
            uint tokenBalance = topTokens[i].balanceOf(address(this));
            
            if (tokenBalance > 0) {
            
                uint sellAmount = (tokenBalance * _percent) / 10 ** 18; // because percent is multiplied by 10 ** 18
    
                _sellERCToken(topTokens[i], sellAmount, _receiver);
            
                // check if leftover balance if too low and selling everything would make sense
            
            }
        }
    }
    
    // when selling, also claim you share of DAI the fund is holding
    function _claimDai(uint _percent) internal {
    
        uint daiAmount = (daiToken.balanceOf(address(this)) * _percent) / 10 ** 18;
        
        if (daiAmount > 0) {
        
            daiToken.transfer(msg.sender, daiAmount);
        
        }    
    }
    
    function _sellERCToken(ERC20 _token, uint _amount, address _receiver) internal {
        
        require(_token.approve(address(myUniswapProxy), _amount)); // so it can sell the token
        
        myUniswapProxy.executeSwap(_token, _amount, daiToken, _receiver); // send dai to user
        
    }
    
    // disable purchasing of ERCI and sell all tokens for DAI
    function exit() isOwner public {
        
        isActive = false;
        
        // sell 100% of index for dai
        _sellPercentOfIndexForDai(10 ** 18, address(this)); // will send DAI to contract
        
    }

}
