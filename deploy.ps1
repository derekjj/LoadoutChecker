# Copies the addon from this repo into the WoW AddOns folder for in-game testing.
# Usage: .\deploy.ps1            (then /reload in game)
param(
    [string]$Target = "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\LoadoutCheck"
)

$source = $PSScriptRoot

# Mirror the addon files only; repo-only files (docs, media, tooling) stay behind.
robocopy $source $Target /MIR /NJH /NJS /NDL /NP `
    /XD .git .github .release media `
    /XF *.md LICENSE .pkgmeta .gitignore .gitattributes deploy.ps1 *.zip | Out-Host

# robocopy exit codes below 8 mean success
if ($LASTEXITCODE -ge 8) { exit $LASTEXITCODE }
Write-Host "Deployed to $Target - /reload in game to pick up changes."
exit 0
