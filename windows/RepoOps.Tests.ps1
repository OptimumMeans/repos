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
