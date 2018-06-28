const marketplace = artifacts.require("Marketplace");

module.exports = (deployer) => {
    deployer.deploy(marketplace);
}