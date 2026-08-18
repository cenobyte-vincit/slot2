# Agents

slot2 is a compiled C installer plus Amazon Linux 2023 build scripts. The **build host** is Amazon Linux 2023 x86_64. The **runtime host** is the **target** (an EC2 instance of that same class) and has no compiler, headers, `make`, or cppcheck unless they happen to be installed for other reasons.

This checkout may sit on a Mac. That machine is not the build host and not the target. Do not run `make`, `cc`, `grub2-mkimage`, or `./install-dependencies.sh` here.

`make`, `cc`, **cppcheck**, `grub2-mkimage`, `objcopy`, and `./install-dependencies.sh` are build-host only. Do not treat clone-and-compile as a deploy path onto the target. Copy the shipped `deploy` ELF.

Colocated build-and-install on one AL2023 instance is allowed for a short test. `make` does not write the ESP, `/var/lib/systemd/boot`, or NVRAM. Colocated `make` is not a clean-runtime proof.

Do not replace stock `\EFI\BOOT\BOOTX64.EFI` or packaged GRUB. Dracut hooks must `return`, never `exit`. UKI path, ESP PE name, `BOOTKIT_MARKER`, and trailer magic are lockstep constants (ARCHITECTURE.md).

See README.md for the operator surface and ARCHITECTURE.md for the boot chain and host model.
