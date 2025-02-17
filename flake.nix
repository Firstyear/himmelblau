{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system};
          rustPlatform = pkgs.rustPlatform;
          cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
          recipe = {lib, enableInteractive ? false}: rustPlatform.buildRustPackage {
            pname = "himmelblau";
            version = cargoToml.workspace.package.version;
            src = with lib.fileset; toSource {
              root = ./.;
              fileset = difference (gitTracked ./.) (fileFilter
                (file: file.hasExt "nix" || file.hasExt "md" || file == "Makefile") ./.);
            };
            outputs = [ "out" "man" ];
            cargoLock = {
              lockFile = ./Cargo.lock;
              allowBuiltinFetchGit = true;
            };

            buildFeatures = lib.optionals enableInteractive [ "interactive" ];
            nativeBuildInputs = [
              pkgs.pkg-config rustPlatform.bindgenHook
            ];
            buildInputs = with pkgs; [
              talloc tevent ding-libs utf8proc
              sqlite.dev openssl.dev libcap.dev
              ldb.dev krb5.dev pcre2.dev
              pam dbus.dev udev.dev
            ] ++ lib.optionals enableInteractive [
              gobject-introspection.dev cairo.dev gdk-pixbuf.dev
              libsoup.dev pango.dev atk.dev gtk3.dev webkitgtk_4_1
            ];
            postBuild = "cp -r man $man/";
            postInstall = "ln -s $out/lib/libnss_himmelblau.so $out/lib/libnss_himmelblau.so.2";
            meta = with lib; {
              description = "Himmelblau is an interoperability suite for Microsoft Azure Entra ID and Intune.";
              homepage = "https://github.com/himmelblau-idm/himmelblau";
              license = licenses.gpl3Plus;
              maintainers = [{
                name = "David Mulder";
                email = "dmulder@samba.org";
                github = "dmulder";
              }];
              platforms = platforms.linux;
            };
          };
      in rec {
        packages.himmelblau = pkgs.callPackage recipe {};
        packages.himmelblau-desktop = pkgs.callPackage recipe { enableInteractive = true; };
        packages.default = packages.himmelblau;

        devShells.default = pkgs.mkShell {
          name = "himmelblau-devshell";
          inputsFrom = [ packages.himmelblau-desktop ];
          nativeBuildInputs = with pkgs; [ rust-analyzer rustfmt clippy ];
        };

      }) // flake-utils.lib.eachDefaultSystemPassThrough (system: {
        nixosModules.himmelblau = { pkgs, lib, config, ...}:
          let cfg = config.services.himmelblau; in {
            options = with lib; {
              services.himmelblau = {
                enable = mkEnableOption "Himmelblau";

                package = mkOption {
                  type = types.path;
                  default = self.packages.${system}.default;
                  description = "Package to use for Himmelblau service.";
                };

                debugFlag = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Whether to pass the debug (-d) flag to the himmelblaud binary.";
                };

                pamServices = mkOption {
                  type = types.listOf types.str;
                  default = ["passwd" "login" "su"];
                  description = "Which PAM services to add the himmelblau module to.";
                };

                settings = {  # settings submodule https://github.com/NixOS/rfcs/pull/42
                  domains = mkOption {
                    type = types.listOf types.str;
                    example = [ "my.domain.com" ];
                    description = ''
                      REQUIRED: The list of configured domains. This must be specified, or no users
                      will be permitted to authenticate. The first user to authenticate to each
                      domain will be the owner of the device object in the directory. Typically
                      this would be the primary user of the device.
                    '';
                  };
                  debug = mkOption {
                    type = types.bool;
                    default = false;
                    description = ''
                      Configure whether the logger will output debug messages to the journal.
                    '';
                  };
                  pam_allow_groups = mkOption {
                    type = types.listOf types.str;
                    example = [ "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" ];
                    description = ''
                      pam_allow_groups SHOULD be defined or else all users will be authorized by
                      pam account. The option should be set to a comma seperated list of Users and
                      Groups which are allowed access to the system. Groups MUST be specified by
                      Object ID, not by UPN. This is because Azure does not permit regular users
                      the right to read group names, only the Object IDs which they belong to.
                    '';
                  };
                  id_attr_map = mkOption {
                    type = types.enum [ "name" "uuid" ];
                    default = "name";
                    description = ''
                      Specify whether to map uid/gid based on the object name or the object uuid.
                      By object uuid mapping is the old default, but can cause authentication
                      issues over SSH. Mapping by name is recommeneded.
                    '';
                  };
                  odc_provider = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "odc.officeapps.live.com";
                    description = ''
                      If you have an ODC provider (the default being odc.officeapps.live.com), specify
                      the hostname for sending a federationProvider request. If the federationProvider
                      request is successful, the tenant_id and authority_host options do not need to
                      be specified.
                    '';
                  };
                  enable_hello = mkOption {
                    type = types.bool;
                    default = true;
                    description = ''
                      Whether to enroll users in Hello authentication. If disabled, MFA may be
                      required during each login. Disabling Hello authentication is recommeneded
                      when the host is public facing (such as via SSH).
                      WARNING: Hello authentication depends on openssl3. If your system does not
                      provide openssl3, Hello MUST be disabled or authentication will fail.
                      EL8 distros (such as Rocky Linux 8) DO NOT provide openssl3.
                    '';
                  };
                  hello_pin_min_length = mkOption {
                    type = types.int;
                    default = 6;
                    description = ''
                      The minimum length of the Hello authentication PIN. This PIN length cannot
                      be less than 6, and cannot exceed 32 characters. These are hard requirements
                      for the encryption algorithm.
                    '';
                  };
                  enable_sfa_fallback = mkOption {
                    type = types.bool;
                    default = false;
                    description = ''
                      Whether to permit attempting a SFA (password only) authentication when MFA
                      methods are unavailable. Sometimes this is possible when MFA has yet to be
                      configured. This is disabled by default.
                    '';
                  };
                  enable_experimental_mfa = mkOption {
                    type = types.bool;
                    default = true;
                    description = ''
                      This option enables the experimental MFA (multi-factor authentication) flow,
                      which permits Hello authentication. Note that this flow may fail in certain
                      edge cases. When disabled, the system will enforce the DAG (Device Authorization
                      Grant) flow for MFA, and Hello authentication will be disabled.
                    '';
                  };
                  cn_name_mapping = mkOption {
                    type = types.bool;
                    default = true;
                    description = ''
                      CN to UPN mapping allows users to simply enter the short form of their
                      username (`dave` instead of `dave@example.com`). Himmelblau will only map CNs
                      to the primary domain (the first domain listed in the `domains` option
                      above). WARNING: CN mapping could mask local users, depending on your PAM
                      configuration.
                    '';
                  };
                  local_groups = mkOption {
                    type = types.listOf types.str;
                    default = [];
                    example = [ "docker" ];
                    description = ''
                      A comma seperated list of local groups that every Entra Id user should be a
                      member of. For example, you may wish for all Entra Id users to be a member
                      of the sudo group. WARNING: This setting will not REMOVE group member entries
                      when groups are removed from this list. You must remove them manually.
                    '';
                  };
                  logon_script = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "./logon.sh";
                    description = ''
                      Logon user script. This script will execute every time a user logs on. Two
                      environment variables are set: USERNAME, and ACCESS_TOKEN. The ACCESS_TOKEN
                      environment variable is an access token for the MS graph.
                    '';
                  };
                  logon_token_scopes = mkOption {
                    type = types.nullOr (types.listOf types.str);
                    default = null;
                    description = ''
                      The token scope config option sets the comma separated scopes that should be
                      requested for the ACCESS_TOKEN. ACCESS_TOKEN will be empty during offline logon.
                      The return code of the script determines how the authentication proceeds. 0 is
                      success, 1 is a soft failure and authentication will proceed, while 2 is a hard
                      failure causing authentication to fail.
                    '';
                  };
                  tenant_id = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX";
                  };
                  app_id = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX";
                  };
                  authority_host = mkOption {
                    type = types.str;
                    default = "login.microsoftonline.com";
                  };

                  db_path = mkOption {
                    type = types.str;
                    default = "/var/cache/himmelblaud/himmelblau.cache.db";
                    description = "The location of the cache database";
                  };
                  hsm_pin_path = mkOption {
                    type = types.str;
                    default = "/var/lib/himmelblaud/hsm-pin";
                    description = "The location where the hsm pin will be stored";
                  };
                  socket_path = mkOption {
                    type = types.str;
                    default = "/var/run/himmelblaud/socket";
                  };
                  task_socket_path = mkOption {
                    type = types.str;
                    default = "/var/run/himmelblaud/task_sock";
                  };
                  broker_socket_path = mkOption {
                    type = types.str;
                    default = "/var/run/himmelblaud/broker_sock";
                  };

                  home_prefix = mkOption {
                    type = types.str;
                    default = "/home/";
                  };
                  home_attr = mkOption {
                    type = types.enum [ "UUID" "SPN" "CN" ];
                    default = "UUID";
                  };
                  home_alias = mkOption {
                    type = types.enum [ "UUID" "SPN" "CN" ];
                    default = "SPN";
                  };
                  shell = mkOption {
                    type = types.path;
                    default = "/run/current-system/sw/bin/bash";
                  };

                  idmap_range = mkOption {
                    type = types.str;
                    default = "5000000-5999999";
                  };
                  connection_timeout = mkOption {
                    type = types.ints.unsigned;
                    default = 2;
                  };
                  cache_timeout = mkOption {
                    type = types.ints.unsigned;
                    default = 300;
                  };
                  use_etc_skel = mkOption {
                    type = types.bool;
                    default = false;
                  };
                  selinux = mkOption {
                    type = types.bool;
                    default = false;
                  };
                };
              };
            };

            config = lib.mkIf cfg.enable {
              # TODO: replace with lib.generators.toINI
              environment.etc."himmelblau/himmelblau.conf".text = ''
                [global]
                domains = ${builtins.concatStringsSep "," cfg.settings.domains}
                debug = ${if cfg.settings.debug then "true" else "false"}
                pam_allow_groups = ${builtins.concatStringsSep "," cfg.settings.pam_allow_groups}
                id_attr_map = ${cfg.settings.id_attr_map}
              '' + lib.optionalString (!builtins.isNull cfg.settings.odc_provider) ''
                odc_provider = ${cfg.settings.odc_provider}
              '' + ''
                enable_hello = ${if cfg.settings.enable_hello then "true" else "false"}
                hello_pin_min_length = ${builtins.toString cfg.settings.hello_pin_min_length}
                enable_sfa_fallback = ${if cfg.settings.enable_sfa_fallback then "true" else "false"}
                enable_experimental_mfa = ${if cfg.settings.enable_experimental_mfa then "true" else "false"}
                cn_name_mapping = ${if cfg.settings.cn_name_mapping then "true" else "false"}
              '' + lib.optionalString (cfg.settings.local_groups != []) ''
                local_groups = ${builtins.concatStringsSep "," cfg.settings.local_groups}
              '' + lib.optionalString (!builtins.isNull cfg.settings.logon_script) ''
                logon_script = ${cfg.settings.logon_script}
              '' + lib.optionalString (!builtins.isNull cfg.settings.logon_token_scopes) ''
                logon_token_scopes = ${builtins.concatStringsSep "," cfg.settings.logon_token_scopes}
              '' + lib.optionalString (!builtins.isNull cfg.settings.tenant_id) ''
                tenant_id = ${cfg.settings.tenant_id}
              '' + lib.optionalString (!builtins.isNull cfg.settings.app_id) ''
                app_id = ${cfg.settings.app_id}
              '' + ''
                authority_host = ${cfg.settings.authority_host}
                db_path = ${cfg.settings.db_path}
                hsm_pin_path = ${cfg.settings.hsm_pin_path}
                socket_path = ${cfg.settings.socket_path}
                task_socket_path = ${cfg.settings.task_socket_path}
                broker_socket_path = ${cfg.settings.broker_socket_path}
                home_prefix = ${cfg.settings.home_prefix}
                home_attr = ${cfg.settings.home_attr}
                home_alias = ${cfg.settings.home_alias}
                shell = ${cfg.settings.shell}
                idmap_range = ${cfg.settings.idmap_range}
                connection_timeout = ${builtins.toString cfg.settings.connection_timeout}
                cache_timeout = ${builtins.toString cfg.settings.cache_timeout}
                use_etc_skel = ${if cfg.settings.use_etc_skel then "true" else "false"}
                selinux = ${if cfg.settings.selinux then "true" else "false"}
              ''; # TODO: Support Per-Domain Customisation
              environment.etc."krb5.conf.d/krb5_himmelblau.conf".source = ./src/config/krb5_himmelblau.conf;

              # Add himmelblau to the list of name services to lookup users/groups
              system.nssModules = [ cfg.package ];
              system.nssDatabases.passwd = [ "himmelblau" ];  # will be merged with entries from other modules
              system.nssDatabases.group  = [ "himmelblau" ];  # will be merged with entries from other modules
              system.nssDatabases.shadow = [ "himmelblau" ];  # will be merged with entries from other modules

              # Add entries for authenticating users via pam
              security.pam.services = let
                genServiceCfg = service: {
                  rules = let super = config.security.pam.services.${service}.rules; in {
                    account.himmelblau = {
                      order = super.account.unix.order - 10;
                      control = "sufficient";
                      modulePath = "${cfg.package}/lib/libpam_himmelblau.so";
                      settings.ignore_unknown_user = true;
                      settings.debug = cfg.debugFlag;
                    };
                    auth.himmelblau = {
                      order = super.auth.unix.order - 10;
                      control = "sufficient";
                      modulePath = "${cfg.package}/lib/libpam_himmelblau.so";
                      settings.debug = cfg.debugFlag;
                    };
                    session.himmelblau = {
                      order = super.session.unix.order - 10;
                      control = "optional";
                      modulePath = "${cfg.package}/lib/libpam_himmelblau.so";
                      settings.debug = cfg.debugFlag;
                    };
                  };
                };
                services = cfg.pamServices
                  ++ lib.optional config.security.sudo.enable "sudo"
                  ++ lib.optional config.security.doas.enable "doas"
                  ++ lib.optional config.services.sshd.enable "sshd";
              in lib.genAttrs services genServiceCfg;

              systemd.services = let
                commonServiceConfig = {
                  Type="notify";
                  UMask = "0027";
                  # SystemCallFilter = "@aio @basic-io @chown @file-system @io-event @network-io @sync";
                  NoNewPrivileges = true;
                  PrivateDevices = true;
                  ProtectHostname = true;
                  ProtectClock = true;
                  ProtectKernelTunables = true;
                  ProtectKernelModules = true;
                  ProtectKernelLogs = true;
                  ProtectControlGroups = true;
                  MemoryDenyWriteExecute = true;
                };
              in {
                himmelblaud = {
                  description = "Himmelblau Authentication Daemon";
                  wants = [ "chronyd.service" "ntpd.service" "network-online.target" ];
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig = commonServiceConfig // {
                    ExecStart = "${cfg.package}/bin/himmelblaud" + lib.optionalString cfg.debugFlag " -d";
                    Restart = "on-failure";
                    DynamicUser = "yes";
                    CacheDirectory = "himmelblaud"; # /var/cache/himmelblaud
                    RuntimeDirectory = "himmelblaud"; # /var/run/himmelblaud
                    StateDirectory = "himmelblaud"; # /var/lib/himmelblaud
                    PrivateTmp = true;
                    # We have to disable this to allow tpmrm0 access for tpm binding.
                    PrivateDevices = false;
                  };
                };

                himmelblaud-tasks = {
                  description = "Himmelblau Local Tasks";
                  bindsTo = [ "himmelblaud.service" ];
                  wantedBy = [ "multi-user.target" ];
                  path = [ pkgs.shadow pkgs.bash ];
                  serviceConfig = commonServiceConfig // {
                    ExecStart = "${cfg.package}/bin/himmelblaud_tasks";
                    Restart = "on-failure";
                    User = "root";
                    ProtectSystem = "strict";
                    ReadWritePaths = "/home /var/run/himmelblaud /tmp /etc/krb5.conf.d /etc";
                    RestrictAddressFamilies = "AF_UNIX";
                  };
                };
              };
            };
          };

        nixosConfigurations.testing = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [({pkgs, lib, ...}: {
            imports = [ self.nixosModules.himmelblau ];
            boot.isContainer = true;  # stop nix flake check complaining about missing root fs
            documentation.nixos.enable = false;  # skip generating nixos docs
            virtualisation.vmVariant = {
              boot.isContainer = lib.mkForce false;  # let vm variant create a virtual disk
              virtualisation.graphics = false;  # connect serial console to terminal
            };
            nix.nixPath = ["nixpkgs=${nixpkgs}"];
            users.users.root.initialPassword = "test";
            services.sshd.enable = true;
            services.himmelblau = {
              enable = true;
              settings = {
                domains = ["example.com"];
                pam_allow_groups = [ "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" ];
              };
            };
            environment.systemPackages = with pkgs; [ pamtester ];
          })];
        };
      });
}
