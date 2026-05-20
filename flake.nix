{
  description = "Mofakir - A lightweight, agentic AI Desktop Assistant";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs allSystems (system: f nixpkgs.legacyPackages.${system});
      voicesDict = import ./voices.nix;
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          pythonEnv = pkgs.python3.withPackages (
            ps: with ps; [
              openai
              ddgs
              requests
              beautifulsoup4
              langdetect
              edge-tts
              pyqt6
            ]
          );

          # Whisper is mandatory, so it stays hardcoded here
          whisperSmall = pkgs.fetchurl {
            url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin";
            sha256 = "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f";
          };

          # Wrap the derivation in a function so it can be overridden by the user!
          mofakir-derivation =
            {
              voices ? [ "en_US-lessac-medium" ],
            }:
            pkgs.stdenv.mkDerivation rec {
              pname = "mofakir";
              version = "1.0.0";

              src = ./.;

              buildInputs = [
                pythonEnv
                pkgs.qt6.qtbase
                pkgs.qt6.qtwayland
              ];
              nativeBuildInputs = [
                pkgs.makeWrapper
                pkgs.sox
                pkgs.qt6.wrapQtAppsHook
              ];

              # Dynamically generate the copy commands ONLY for the requested voices
              fetchedVoices = pkgs.lib.concatMapStringsSep "\n" (
                voiceName:
                let
                  v = voicesDict.${voiceName};
                  onnxFile = pkgs.fetchurl {
                    url = v.onnxUrl;
                    sha256 = v.onnxHash;
                  };
                  jsonFile = pkgs.fetchurl {
                    url = v.jsonUrl;
                    sha256 = v.jsonHash;
                  };
                in
                ''
                  cp ${onnxFile} $out/share/mofakir/models/${voiceName}.onnx
                  cp ${jsonFile} $out/share/mofakir/models/${voiceName}.onnx.json
                ''
              ) voices;

              installPhase = ''
                mkdir -p $out/bin $out/libexec $out/share/mofakir/sounds $out/share/mofakir/models

                if [ -d "sounds" ] && [ "$(ls -A sounds 2>/dev/null)" ]; then
                  cp sounds/* $out/share/mofakir/sounds/
                else
                  sox -n $out/share/mofakir/sounds/start.wav synth 0.1 sine 800 vol 0.5
                  sox -n $out/share/mofakir/sounds/stop.wav synth 0.15 sine 400 vol 0.5
                fi

                cp src/ui.qml $out/share/mofakir/ui.qml

                cp ${whisperSmall} $out/share/mofakir/models/ggml-small.bin

                ${fetchedVoices}

                cp trigger.sh $out/libexec/mofakir-unwrapped
                chmod +x $out/libexec/mofakir-unwrapped

                cp src/mofakir-gui.py $out/bin/mofakir-gui
                chmod +x $out/bin/mofakir-gui

                cat << 'EOF' > $out/bin/mofakir
                #!/usr/bin/env bash
                mkdir -p "$HOME/.local/share/mofakir/sounds" "$HOME/.local/share/mofakir/models"

                ln -sf @out@/share/mofakir/sounds/* "$HOME/.local/share/mofakir/sounds/"
                ln -sf @out@/share/mofakir/models/* "$HOME/.local/share/mofakir/models/"

                export PATH="@path@:$PATH"
                exec @out@/libexec/mofakir-unwrapped "$@"
                EOF

                substituteInPlace $out/bin/mofakir \
                  --replace "@out@" "$out" \
                  --replace "@path@" "${
                    pkgs.lib.makeBinPath [
                      pkgs.sox
                      pkgs.jq
                      pkgs.piper-tts
                      pkgs.whisper-cpp
                      pkgs.wl-clipboard
                      pkgs.grim
                      pkgs.playerctl
                      pkgs.wireplumber
                      pkgs.xclip
                      pkgs.maim
                      pkgs.xdotool
                      pkgs.wmctrl
                      pythonEnv
                    ]
                  }:$out/bin"
                  
                chmod +x $out/bin/mofakir
                  
                wrapProgram $out/bin/mofakir-gui \
                  --prefix PATH : ${
                    pkgs.lib.makeBinPath [
                      pkgs.sox
                      pkgs.piper-tts
                      pkgs.whisper-cpp
                      pkgs.wireplumber
                      pkgs.wmctrl
                      pythonEnv
                    ]
                  }
              '';
            };
        in
        {
          default = pkgs.callPackage mofakir-derivation { };
        }
      );

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/mofakir";
        };
      });

      homeManagerModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.mofakir;

          shortToFull = {
            "en" = "en_US-lessac-medium";
            "ar" = "ar_JO-kareem-medium";
            "fr" = "fr_FR-upmc-medium";
            "es" = "es_ES-sharvard-medium";
            "de" = "de_DE-thorsten-medium";
            "it" = "it_IT-riccardo-xlow";
            "ja" = "ja_JP-dani-low";
            "pt" = "pt_PT-tugao-medium";
            "ru" = "ru_RU-denis-medium";
            "zh" = "zh_CN-huashan-medium";
          };
        in
        {
          options.programs.mofakir = {
            enable = lib.mkEnableOption "Mofakir AI Desktop Assistant";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              description = "The Mofakir package to install.";
            };
            settings = lib.mkOption {
              type = lib.types.attrs;
              default = { };
            };
            context = lib.mkOption {
              type = lib.types.lines;
              default = "";
            };
          };

          config = lib.mkIf cfg.enable (
            let
              requestedVoices =
                if cfg.settings ? voice && cfg.settings.voice ? tts_offline_voices then
                  cfg.settings.voice.tts_offline_voices
                else
                  [ "en" ];

              mappedVoices = map (v: shortToFull.${v} or shortToFull."en") requestedVoices;

              generatedLocalModels = builtins.listToAttrs (
                map (v: {
                  name = v;
                  value = "~/.local/share/mofakir/models/${shortToFull.${v} or shortToFull."en"}.onnx";
                }) requestedVoices
              );

              finalSettings = cfg.settings // {
                voice = (cfg.settings.voice or { }) // {
                  tts_local_models = generatedLocalModels;
                };
              };
            in
            {
              home.packages = [
                (cfg.package.override { voices = mappedVoices; })
              ];

              xdg.configFile."mofakir/config.json" = lib.mkIf (finalSettings != { }) {
                text = builtins.toJSON finalSettings;
              };
              xdg.configFile."mofakir/context.md" = lib.mkIf (cfg.context != "") { text = cfg.context; };
            }
          );
        };
    };
}
