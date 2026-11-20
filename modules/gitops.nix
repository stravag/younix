{ ... }:

{
  # GitOps pull-based deployment via comin (https://github.com/nlewo/comin)
  # Polls the GitHub repository and automatically rebuilds & switches on new commits.
  #
  # Tip: Push to a `testing-younix` branch to test changes safely (`switch-to-configuration test`,
  # which reverts automatically on reboot if anything breaks).
  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "https://github.com/stravag/younix.git";
        poller.period = 60;
        branches.main.name = "main";
      }
    ];
  };
}
