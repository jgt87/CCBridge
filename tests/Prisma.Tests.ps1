# Prisma support: the schema check by fixed rules (Lint Test-Prisma), .env names for env("..."),
# prisma validate's output read back (as printed by Prisma 6.19), commands that need a terminal or
# delete data, and the Prisma rules for Copilot. No Prisma installed here: validate is not run.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force

$good = @'
// Quality gates
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "sqlite"
  url      = env("DATABASE_URL")
}

/// A gate in the model designer
model Gate {
  id        Int       @id @default(autoincrement())
  name      String    @unique
  status    Status    @default(DRAFT)
  createdAt DateTime  @default(now())
  updatedAt DateTime  @updatedAt
  checks    Check[]
  owner     User?     @relation("OwnedGates", fields: [ownerId], references: [id])
  ownerId   Int?
  @@index([status])
  @@map("gates")
}

model Check {
  id      String @id @default(cuid())
  gate    Gate   @relation(fields: [gateId], references: [id], onDelete: Cascade)
  gateId  Int
  score   Decimal
  data    Json?
}

model User {
  id     Int    @id
  email  String @unique
  gates  Gate[] @relation("OwnedGates")
}

model Tag {
  key   String
  value String
  @@id([key, value])
}

enum Status {
  DRAFT
  ACTIVE   @map("active")
  @@map("gate_status")
}
'@

Describe 'Prisma schema check (fixed rules)' {
    It 'passes a correct schema with relations, enums, block attributes and comments' {
        @(Test-FileContent 'prisma/schema.prisma' $good) | Should BeNullOrEmpty
    }
    It 'finds brackets, unknown types, duplicates and optional lists' {
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('model Check {', 'model Check')) | Should Match "'\}' closes nothing"
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('name      String    @unique', 'name      Strng    @unique')) | Should Match 'line 14: name has the type Strng, .*did you mean String'
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('  checks    Check[]', "  checks    Check[]`n  name      String")) | Should Match 'has the field name twice'
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('data    Json?', 'data    String[]?')) | Should Match 'optional list'
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('  ACTIVE   @map("active")', "  ACTIVE   @map(`"active`")`n  DRAFT")) | Should Match 'enum Status has DRAFT twice'
        @(Test-FileContent 'prisma/schema.prisma' ($good + "`nmodel Gate {`n  id Int @id`n}`n")) -join ' ' | Should Match 'Gate is defined twice'
        @(Test-FileContent 'prisma/schema.prisma' ($good.Replace('score   Decimal', 'score   decimal'))) -join ' ' | Should Match 'type decimal, .*did you mean Decimal'
    }
    It 'finds unknown attributes, a model without an id and a wrong provider' {
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('@updatedAt', '@updatedat')) | Should Match '@updatedat is not a Prisma field attribute'
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('@@index([status])', '@@indexes([status])')) | Should Match '@@indexes is not a Prisma block attribute'
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('  @@id([key, value])', '')) | Should Match 'model Tag has no @id'
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('"sqlite"', '"sqlitee"')) | Should Match "'sqlitee' is not a database Prisma knows"
        Test-FileContent 'prisma/schema.prisma' ($good + "`nmodels Extra {`n}`n") | Should Match 'is not part of a block'
    }
    It 'checks relations: fields and references that exist, and a field pointing back' {
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('fields: [gateId]', 'fields: [gateIdd]')) | Should Match '@relation fields: \[gateIdd\] names a field that Check does not have'
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('references: [id], onDelete', 'references: [code], onDelete')) | Should Match 'references: \[code\] names a field that Gate does not have'
        Test-FileContent 'prisma/schema.prisma' ($good.Replace('  gates  Gate[] @relation("OwnedGates")', '')) | Should Match 'the relation owner to User has no field pointing back in User'
    }
}

Describe 'Prisma schema against the project' {
    $p = Join-Path $env:TEMP ('ccb-prisma-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory (Join-Path $p 'prisma') -Force | Out-Null
    It 'wants env("...") names in .env and a url, reading only the names' {
        @(Test-PrismaEnv $good 'prisma/schema.prisma' $p) -join ' ' | Should Match 'env\("DATABASE_URL"\) is not set: add DATABASE_URL=\.\.\. to the project''s \.env'
        [IO.File]::WriteAllText((Join-Path $p '.env'), "DATABASE_URL=`"file:./dev.db`"`n")
        @(Test-PrismaEnv $good 'prisma/schema.prisma' $p) | Should BeNullOrEmpty
        $nourl = $good.Replace('  url      = env("DATABASE_URL")', '')
        @(Test-PrismaEnv $nourl 'prisma/schema.prisma' $p) -join ' ' | Should Match 'datasource db has no url'
        [IO.File]::WriteAllText((Join-Path $p 'prisma.config.ts'), 'export default {}')
        @(Test-PrismaEnv $nourl 'prisma/schema.prisma' $p) | Should BeNullOrEmpty   # the url lives in prisma.config
    }
    It 'reports those through the change check, and runs nothing without Prisma installed' {
        Remove-Item (Join-Path $p '.env')
        @(Get-NewFileIssues 'prisma/schema.prisma' '' $good $false $p) -join ' ' | Should Match 'DATABASE_URL'
        Find-PrismaCli $p 'prisma/schema.prisma' | Should BeNullOrEmpty
        @(Test-PrismaValidate $p 'prisma/schema.prisma') | Should BeNullOrEmpty
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    It 'reads prisma validate errors with their line, and ignores messages about Prisma itself' {
        $out = "Environment variables loaded from .env`nPrisma schema loaded from prisma\schema.prisma`n`nError: Prisma schema validation - (validate wasm)`nError code: P1012`nerror: Type `"Strng`" is neither a built-in type, nor refers to another model, composite type, or enum.`n  -->  prisma\schema.prisma:14`n   | `n13 |   id        Int       @id @default(autoincrement())`n14 |   name      Strng    @unique`n   | `n`nValidation Error Count: 1"
        @(ConvertFrom-PrismaValidate $out 'prisma/schema.prisma') -join '|' | Should Be 'line 14: prisma says: Type "Strng" is neither a built-in type, nor refers to another model, composite type, or enum.'
        @(ConvertFrom-PrismaValidate 'Assertion failed: !(handle->flags & UV_HANDLE_CLOSING), file src\win\async.c, line 76' 'prisma/schema.prisma') | Should BeNullOrEmpty
        @(ConvertFrom-PrismaValidate 'Error: Failed to fetch the engine file' 'prisma/schema.prisma') | Should BeNullOrEmpty
    }
}

Describe 'Prisma commands' {
    It 'refuses commands that need a terminal or keep running, with the way that works' {
        Get-UselessCheckCommand 'npx prisma migrate dev --name gates --create-only' | Should Match 'npx prisma db push.*migrate diff.*migrate deploy'
        Get-UselessCheckCommand 'npx prisma studio' | Should Match 'keeps running'
        Get-UselessCheckCommand 'npx prisma migrate dev --help' | Should BeNullOrEmpty
        Get-UselessCheckCommand 'npx prisma migrate deploy' | Should BeNullOrEmpty
        Get-UselessCheckCommand 'npx prisma db push' | Should BeNullOrEmpty
    }
    It 'treats commands that delete database data as deleting data' {
        (Get-CommandRisk 'npx prisma migrate reset --force').destructive | Should Be $true
        (Get-CommandRisk 'npx prisma db push --accept-data-loss').destructive | Should Be $true
        (Get-CommandRisk 'npx prisma db push --force-reset').destructive | Should Be $true
        (Get-CommandRisk 'npx prisma db push').destructive | Should Be $false
        (Get-CommandRisk 'npx prisma generate').destructive | Should Be $false
    }
}

Describe 'Prisma rules for Copilot' {
    It 'go out for a project with a schema or a request that names Prisma, and not otherwise' {
        @(& (Get-Module Prompts) { Get-ProjectTraits @('prisma/schema.prisma', 'src/app.ts') }) -contains 'prisma' | Should Be $true
        $ids = @(& (Get-Module Prompts) { Get-PromptModules -Text 'Add a gates table' -Context @{ Paths = @('prisma/schema.prisma', 'src/app.ts'); Traits = @('code', 'prisma') } })
        $ids -contains 'rules:prisma' | Should Be $true
        $ids = @(& (Get-Module Prompts) { Get-PromptModules -Text 'Set up Prisma with SQLite' -Context @{ Paths = @('src/app.ts'); Traits = @('code') } })
        $ids -contains 'rules:prisma' | Should Be $true
        $ids = @(& (Get-Module Prompts) { Get-PromptModules -Text 'Add a gates table' -Context @{ Paths = @('src/app.ts'); Traits = @('code') } })
        $ids -contains 'rules:prisma' | Should Be $false
        $rules = [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\prisma.md'))
        $rules | Should Match 'Never prisma migrate dev or prisma studio'
        $rules | Should Not Match 'CCBridge|StreamHub'
    }
}
