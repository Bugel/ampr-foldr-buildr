# Ampr Foldr Buildr

Builds ShadowMount backport folders for ampr_emu. It reads the game list from https://apr-tracker.netlify.app/ and writes one folder per PPSA ID.

## Run

```bat
ampr-foldr-buildr.cmd -AprSource "C:\path\to\ampr_emu"
```

Working titles only:

```bat
ampr-foldr-buildr.cmd -AprSource "C:\path\to\ampr_emu" -Status Working
```

If PowerShell blocks scripts, use the `.cmd` file above. It does not change your execution policy.

## Output

```
export/data/homebrew/backports/PPSAxxxxx/fakelib/libSceAmpr.sprx
```

Do not upload `export/.buildr/`. That folder is for the PC build only.

## Copy to PS5

Copy `export/data/` to `/data/` on the console.

ShadowMount uses:

```
/data/homebrew/backports/PPSAxxxxx/fakelib/libSceAmpr.sprx
```

Only games with a folder get the fakelib. Other games are not affected.


Set the following settings in /data/shadowmount/config.ini
backport_fakelib=1
global_fakelib=0
