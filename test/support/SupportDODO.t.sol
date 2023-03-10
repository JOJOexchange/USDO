/*
    Copyright 2022 JOJO Exchange
    SPDX-License-Identifier: BUSL-1.1*/
pragma solidity 0.8.9;

import "forge-std/Test.sol";
import "../../src/support/SupportsDODO.sol";
import "../../src/token/USDO.sol";
import "../mocks/MockERC20.sol";
import "../../src/Impl/JOJOOracleAdaptor.sol";
import "../mocks/MockChainLink.t.sol";

contract SupportDODO is Test {
    SupportsDODO public supportsDODO;
    USDO public usdo;
    MockERC20 public eth;
    MockERC20 public lido;
    JOJOOracleAdaptor public ethAdaptor;
    JOJOOracleAdaptor public lidoAdaptor;
    MockChainLink public ethChainLink;
    MockChainLink public lidoChainLink;

    function setUp() public {
        usdo = new USDO(6);
        eth = new MockERC20(10e18);
        lido = new MockERC20(10e18);

        ethChainLink = new MockChainLink();
        lidoChainLink = new MockChainLink();
        ethAdaptor = new JOJOOracleAdaptor(address(ethChainLink), 20, 86400);
        lidoAdaptor = new JOJOOracleAdaptor(address(lidoChainLink), 20, 86400);
        supportsDODO = new SupportsDODO(
            address(usdo),
            address(eth),
            address(ethAdaptor)
        );
    }

    function testAddToken() public {
        assertEq(ethAdaptor.getAssetPrice(), 1000e6);
        supportsDODO.addTokenPrice(address(lido), address(lidoAdaptor));
        usdo.mint(5000e6);
        usdo.transfer(address(supportsDODO), 5000e6);
        eth.transfer(address(supportsDODO), 5e18);
        lido.transfer(address(supportsDODO), 5e18);

        lido.transfer(address(123), 5e18);
        vm.startPrank(address(123));
        lido.approve(address(supportsDODO), 5e18);
        supportsDODO.swap(1e18, address(lido));
        assertEq(lido.balanceOf(address(123)), 4e18);
        assertEq(usdo.balanceOf(address(123)), 1000e6);
    }
}
