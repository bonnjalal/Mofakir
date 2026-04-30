{
  description = "Mofakir - A lightweight, agentic AI Desktop Assistant";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      allSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs allSystems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenv.mkDerivation rec {
          pname = "mofakir";
          version = "1.0.0";

          src = ./.;

          buildInputs = [
            (pkgs.python3.withPackages (ps: with ps; [
              openai
              duckduckgo-search
              requests
              beautifulsoup4
              tkinter
              langdetect
            ]))
          ];

          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            mkdir -p $out/bin
            
            # Install the bash orchestrator
            cp src/mofakir.sh $out/bin/mofakir
            chmod +x $out/bin/mofakir
            
            # Install the Python GUI/Brain
            cp src/mofakir-gui.py $out/bin/mofakir-gui
            chmod +x $out/bin/mofakir-gui

            # Wrap the bash script so it ALWAYS has access to required tools, 
            # even if the user hasn't installed them globally.
            wrapProgram $out/bin/mofakir \
              --prefix PATH : ${pkgs.lib.makeBinPath [
                pkgs.sox
                pkgs.jq
                pkgs.piper-tts
                pkgs.whisper-cpp
                pkgs.wl-clipboard
                pkgs.grim
                pkgs.playerctl
                pkgs.wireplumber
                pkgs.edge-tts
                $out/bin
              ]}
              
            wrapProgram $out/bin/mofakir-gui \
              --prefix PATH : ${pkgs.lib.makeBinPath [
                pkgs.sox
                pkgs.piper-tts
                pkgs.whisper-cpp
                pkgs.edge-tts
                pkgs.wireplumber
              ]}
          '';
        };
      });
      
      # Default app to execute when running `nix run`
      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/mofakir";
        };
      });
    };
}
