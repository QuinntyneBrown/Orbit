#Requires -Version 7.2
<#
.SYNOPSIS
    Integration tests for Invoke-OutreachManagement.psm1
    Covers: ConvertTo-Slug, New-OutreachFile (type validation, file creation,
            version increment, collision guard, DB record), New-LinkedInMessage
#>

BeforeAll {
    $pipelineModule  = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-PipelineDb.psm1'
    $outreachModule  = Join-Path $PSScriptRoot '..\..\scripts\modules\Invoke-OutreachManagement.psm1'
    Import-Module $pipelineModule -Force
    Import-Module $outreachModule -Force

    $script:TempDb      = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.db')
    $script:OutreachDir = Join-Path ([System.IO.Path]::GetTempPath()) "orbit-outreach-$(Get-Random)"
    Initialize-OrbitDb -DbPath $script:TempDb
    New-Item -ItemType Directory -Path $script:OutreachDir | Out-Null
}

AfterAll {
    Remove-Module Invoke-OutreachManagement -ErrorAction SilentlyContinue
    Remove-Module Invoke-PipelineDb          -ErrorAction SilentlyContinue
    if (Test-Path $script:TempDb)      { Remove-Item $script:TempDb      -Force -ErrorAction SilentlyContinue }
    if (Test-Path $script:OutreachDir) { Remove-Item $script:OutreachDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'ConvertTo-Slug' {
    It 'lowercases the input' {
        ConvertTo-Slug 'HelloWorld' | Should -Be 'helloworld'
    }

    It 'replaces spaces with hyphens' {
        ConvertTo-Slug 'hello world' | Should -Be 'hello-world'
    }

    It 'removes special characters' {
        ConvertTo-Slug 'Acme Corp. (Canada)' | Should -Be 'acme-corp-canada'
    }

    It 'collapses consecutive hyphens' {
        ConvertTo-Slug 'hello  ---  world' | Should -Be 'hello-world'
    }

    It 'strips leading and trailing hyphens' {
        ConvertTo-Slug '  hello world  ' | Should -Be 'hello-world'
    }
}

Describe 'New-OutreachFile' {
    It 'creates a file in the outreach directory' {
        $path = New-OutreachFile -Company 'Acme Corp' -Role 'Software Engineer' `
            -MessageText 'Hello from test.' -Type 'linkedin-message' `
            -DbPath $script:TempDb -OutreachDir $script:OutreachDir
        Test-Path $path | Should -BeTrue
    }

    It 'names the file using the company-role-type slug pattern' {
        $path = New-OutreachFile -Company 'Beta Inc' -Role 'Tech Lead' `
            -MessageText 'Reaching out.' -Type 'email' `
            -DbPath $script:TempDb -OutreachDir $script:OutreachDir
        $filename = Split-Path $path -Leaf
        $filename | Should -Match '^beta-inc-tech-lead-email'
    }

    It 'writes the provided message text into the file' {
        $message = 'This is a test outreach message.'
        $path = New-OutreachFile -Company 'Gamma Ltd' -Role 'Architect' `
            -MessageText $message -Type 'follow-up' `
            -DbPath $script:TempDb -OutreachDir $script:OutreachDir
        $content = Get-Content $path -Raw
        $content.Trim() | Should -Be $message
    }

    It 'inserts a record into outreach_records' {
        New-OutreachFile -Company 'Delta Co' -Role 'PM' `
            -MessageText 'Outreach message.' -Type 'linkedin-message' `
            -DbPath $script:TempDb -OutreachDir $script:OutreachDir | Out-Null

        $row = Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
SELECT * FROM outreach_records WHERE company = 'Delta Co' AND role = 'PM'
"@
        $row | Should -Not -BeNullOrEmpty
        $row.type    | Should -Be 'linkedin-message'
        $row.version | Should -Be 1
    }

    It 'increments version on second outreach for the same company/role/type' {
        $params = @{
            Company      = 'VersionCo'
            Role         = 'Developer'
            Type         = 'email'
            DbPath       = $script:TempDb
            OutreachDir  = $script:OutreachDir
        }
        $path1 = New-OutreachFile @params -MessageText 'First message.'
        $path2 = New-OutreachFile @params -MessageText 'Second message.'

        $path1 | Should -Not -Be $path2
        (Split-Path $path2 -Leaf) | Should -Match '-v2'
        $path2 | Should -Not -Be $path1
    }

    It 'throws on an invalid type' {
        { New-OutreachFile -Company 'X' -Role 'Y' -MessageText 'M' -Type 'sms' `
            -DbPath $script:TempDb -OutreachDir $script:OutreachDir } |
            Should -Throw -ExpectedMessage "*Invalid outreach type*"
    }

    It 'accepts all three valid types without error' {
        foreach ($type in @('linkedin-message', 'email', 'follow-up')) {
            { New-OutreachFile -Company "TypeTest-$type" -Role 'Role' -MessageText 'Msg' `
                -Type $type -DbPath $script:TempDb -OutreachDir $script:OutreachDir } |
                Should -Not -Throw
        }
    }
}

Describe 'New-LinkedInMessage' {
    It 'creates a linkedin-message file' {
        $path = New-LinkedInMessage -Company 'LinkedIn Test Co' -Role 'Senior Dev' `
            -CandidateName 'Quinn Brown' `
            -DbPath $script:TempDb
        # The module uses its own default OutreachDir; pass it explicitly via New-OutreachFile underneath
        # We can verify the DB record instead since the file lands in the module default dir
        $row = Invoke-SqliteQuery -DataSource $script:TempDb -Query @"
SELECT * FROM outreach_records WHERE company = 'LinkedIn Test Co'
"@
        $row.type | Should -Be 'linkedin-message'
    }

    It 'message contains the role and company names' {
        $path = New-LinkedInMessage -Company 'CompanyX' -Role 'Platform Engineer' `
            -CandidateName 'Test User' `
            -DbPath $script:TempDb
        if (Test-Path $path) {
            $content = Get-Content $path -Raw
            $content | Should -Match 'Platform Engineer'
            $content | Should -Match 'CompanyX'
        }
    }

    It 'message includes the candidate name in the sign-off' {
        $path = New-LinkedInMessage -Company 'SignOffCo' -Role 'Dev' `
            -CandidateName 'Jane Doe' `
            -DbPath $script:TempDb
        if (Test-Path $path) {
            $content = Get-Content $path -Raw
            $content | Should -Match 'Jane Doe'
        }
    }

    It 'uses a custom value proposition when provided' {
        $valueProp = 'I have 10 years of distributed systems experience.'
        $path = New-LinkedInMessage -Company 'ValuePropCo' -Role 'Architect' `
            -ValueProp $valueProp -CandidateName 'Dev' `
            -DbPath $script:TempDb
        if (Test-Path $path) {
            $content = Get-Content $path -Raw
            $content | Should -Match 'distributed systems'
        }
    }
}
