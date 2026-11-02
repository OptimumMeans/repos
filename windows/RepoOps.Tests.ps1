BeforeAll {
    . (Join-Path $PSScriptRoot 'RepoOps.ps1')
}

Describe 'Format-SizeMB' {
    It 'floors kilobytes to whole MB' {
        Format-SizeMB 0 | Should -Be 0
        Format-SizeMB 1024 | Should -Be 1
        Format-SizeMB 1536 | Should -Be 1
        Format-SizeMB 1048576 | Should -Be 1024
    }
}

Describe 'Test-RepoOnDisk / Get-RepoDir' {
    BeforeAll {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("repotest_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'alpha\.git') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'beta') | Out-Null
        $env:REPO_DIR = $tmp
    }
    AfterAll {
        $env:REPO_DIR = $null
        Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue
    }
    It 'honors REPO_DIR' { Get-RepoDir | Should -Be $script:tmp }
    It 'is true for a cloned repo' { Test-RepoOnDisk 'alpha' | Should -BeTrue }
    It 'is false for a folder without .git' { Test-RepoOnDisk 'beta' | Should -BeFalse }
    It 'is false for a missing repo' { Test-RepoOnDisk 'ghost' | Should -BeFalse }
}

Describe 'Normalized local-folder matching' {
    BeforeAll {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("reponorm_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'dashd\.git') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'tail-and-veil\.git') | Out-Null
        $env:REPO_DIR = $tmp
    }
    AfterAll {
        $env:REPO_DIR = $null
        Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue
    }
    It 'normalizes punctuation and case' {
        Get-NormalizedName 'Dash-d' | Should -Be 'dashd'
        Get-NormalizedName 'TailAndVeil' | Should -Be 'tailandveil'
    }
    It 'resolves a differently-punctuated GitHub name to the real folder' {
        Resolve-LocalFolder 'Dash-d' | Should -Be 'dashd'
        Resolve-LocalFolder 'TailAndVeil' | Should -Be 'tail-and-veil'
    }
    It 'treats a normalized match as on disk' {
        Test-RepoOnDisk 'Dash-d' | Should -BeTrue
    }
    It 'returns null for a genuinely missing repo' {
        Resolve-LocalFolder 'no-such-repo' | Should -BeNullOrEmpty
    }
}

Describe 'Get-RepoFiles' {
    BeforeAll {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("repofiles_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'proj\src') | Out-Null
        Set-Content -LiteralPath (Join-Path $tmp 'proj\README.md') -Value 'hi'
        Set-Content -LiteralPath (Join-Path $tmp 'proj\src\main.ps1') -Value 'x'
        $env:REPO_DIR = $tmp
    }
    AfterAll {
        $env:REPO_DIR = $null
        Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue
    }
    It 'lists directories before files' {
        $items = Get-RepoFiles 'proj' ''
        $items[0].Name | Should -Be 'src'
        $items[0].IsDir | Should -BeTrue
        ($items | Where-Object { $_.Name -eq 'README.md' }).IsDir | Should -BeFalse
    }
    It 'descends into a subfolder' {
        (Get-RepoFiles 'proj' 'src').Name | Should -Contain 'main.ps1'
    }
    It 'refuses to escape the repo root' {
        Get-RepoFiles 'proj' '..' | Should -BeNullOrEmpty
    }
}

Describe 'Get-RepoUrls' {
    It 'builds clone and web urls' {
        $u = Get-RepoUrls 'OptimumMeans/sift'
        $u.Clone | Should -Be 'https://github.com/OptimumMeans/sift.git'
        $u.Web | Should -Be 'https://github.com/OptimumMeans/sift'
    }
}

Describe 'Get-Repos' {
    It 'shapes gh json into repo objects' {
        function gh { '[{"name":"sift","nameWithOwner":"OptimumMeans/sift","diskUsage":2048},{"name":"aerviz","nameWithOwner":"OptimumMeans/aerviz","diskUsage":148480}]' }
        $env:REPO_DIR = (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')))
        $r = Get-Repos
        $r.Ok | Should -BeTrue
        $r.Repos.Count | Should -Be 2
        ($r.Repos | Where-Object Name -eq 'aerviz').SizeMB | Should -Be 145
        ($r.Repos | Where-Object Name -eq 'sift').Slug | Should -Be 'OptimumMeans/sift'
        $env:REPO_DIR = $null
    }
    It 'reports an error when gh returns nothing' {
        function gh { '' }
        $r = Get-Repos
        $r.Ok | Should -BeFalse
        $r.Error | Should -Match 'gh'
    }
}

Describe 'Format-SizeText' {
    It 'shows MB under 1 GB and GB above' {
        Format-SizeText 0 | Should -Be '0 MB'
        Format-SizeText 900 | Should -Be '900 MB'
        Format-SizeText 1536 | Should -Be '1.5 GB'
        Format-SizeText 42496 | Should -Be '41.5 GB'
    }
}

Describe 'Get-FolderSizeMB / Get-IgnoredLocalOnly' {
    BeforeAll {
        $script:repo = Join-Path ([System.IO.Path]::GetTempPath()) ("repoign_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        git -C $repo init -q
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value "data/`nnode_modules/`n.env"
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'data'), (Join-Path $repo 'node_modules\pkg') | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $repo 'data\big.bin'), (New-Object byte[] (3MB)))
        [System.IO.File]::WriteAllBytes((Join-Path $repo 'node_modules\pkg\x.js'), (New-Object byte[] 10))
        Set-Content -LiteralPath (Join-Path $repo '.env') -Value 'SECRET=1'
        Set-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value 'hi'
    }
    AfterAll { Remove-Item -Recurse -Force $script:repo -ErrorAction SilentlyContinue }

    It 'sums file sizes recursively in MB' {
        Get-FolderSizeMB (Join-Path $repo 'data') | Should -Be 3
    }
    It 'lists ignored data and secrets that only exist locally' {
        $paths = @(Get-IgnoredLocalOnly $repo | ForEach-Object Path)
        $paths | Should -Contain 'data'
        $paths | Should -Contain '.env'
    }
    It 'skips regenerable installs like node_modules' {
        @(Get-IgnoredLocalOnly $repo | ForEach-Object Path) | Should -Not -Contain 'node_modules'
    }
    It 'reports the size of each ignored entry' {
        (Get-IgnoredLocalOnly $repo | Where-Object Path -eq 'data').SizeMB | Should -Be 3
    }
    It 'returns nothing for a repo with no ignored files' {
        $clean = Join-Path ([System.IO.Path]::GetTempPath()) ("repoclean_" + [guid]::NewGuid().ToString('N'))
        git init -q $clean
        @(Get-IgnoredLocalOnly $clean).Count | Should -Be 0
        Remove-Item -Recurse -Force $clean
    }
}
