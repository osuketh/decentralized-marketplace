const marketplace = artifacts.require("marketplace");

module.exports = (deployer) => {
    deployer.deploy(marketplace);
}