pacman -Syu
reboot                    # required to load the new nvidia kernel module
nvidia-smi                # confirm the new version is now actually loaded
./deploy-plh-ai-engine.sh # nuke + rebuild container against the now-current driver
