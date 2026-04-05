# StartHub Project Rules & Conventions

> **Last Updated:** November 20, 2025

This document contains all the rules, conventions, and important instructions for working on the StartHub (Founders Club) project.

## 🔒 Security Rules

- **NEVER** commit secrets or credentials
- **NEVER** update the git config
- **ALWAYS** validate user input
- **USE** TypeScript strict mode
- Never introduce code that exposes or logs secrets and keys

## 🚨 STRICT TYPESCRIPT RULES FOR BACKEND

### ABSOLUTELY FORBIDDEN in /apps/backend:

#### 1. NO `any` TYPE

- ❌ NEVER use `any` type
- ✅ Use specific types, generics, or `unknown` with type guards
- ✅ For truly dynamic data, use `Record<string, unknown>` or create proper interfaces

```typescript
// ❌ FORBIDDEN
function process(data: any) {}

// ✅ CORRECT
function process(data: unknown) {
  if (typeof data === "object" && data !== null && "id" in data) {
    // Type guard ensures safety
  }
}

// ✅ BETTER
interface ProcessData {
  id: string;
  // ... other properties
}
function process(data: ProcessData) {}
```

#### 2. NO `unknown` UNLESS MANDATORY

- ❌ Avoid `unknown` unless absolutely necessary (external APIs, truly dynamic data)
- ✅ Always prefer specific types or interfaces
- ✅ If using `unknown`, MUST have proper type guards

```typescript
// ❌ LAZY USE OF UNKNOWN
function handle(input: unknown) {
  return input; // No type safety
}

// ✅ PROPER USE WITH TYPE GUARDS
function handle(input: unknown): string {
  if (typeof input === "string") {
    return input;
  }
  throw new Error("Invalid input type");
}
```

#### 3. NO `as` TYPE ASSERTIONS UNLESS MANDATORY

- ❌ NEVER use `as` for convenience
- ✅ Use proper type guards and type predicates
- ✅ Only use `as` when TypeScript cannot infer correctly (rare cases)

```typescript
// ❌ FORBIDDEN
const user = req.body as User;

// ✅ CORRECT
const body = req.body;
if (isUser(body)) {
  const user: User = body;
}

// Type predicate
function isUser(obj: unknown): obj is User {
  return (
    typeof obj === "object" && obj !== null && "id" in obj && "email" in obj
  );
}
```

#### 4. NO UNDERSCORE PREFIXES

- ❌ NEVER use `_variableName` or `_methodName`
- ✅ Use `private` keyword for class members
- ✅ Use descriptive names without underscores

```typescript
// ❌ FORBIDDEN
class Service {
  private _cache: Map<string, Data>;
  _internalMethod() {}
}

// ✅ CORRECT
class Service {
  private cache: Map<string, Data>;
  private internalMethod() {}
}
```

#### 5. NO TS/BIOME IGNORES

- ❌ ABSOLUTELY NO `// @ts-ignore`, `// @ts-nocheck`, `// biome-ignore`
- ✅ Fix the actual TypeScript/Biome issues
- ✅ Refactor code to be type-safe

```typescript
// ❌ FORBIDDEN
// @ts-ignore
const result = someUntypedFunction();

// ❌ FORBIDDEN
// biome-ignore lint/suspicious/noExplicitAny
const unused = "variable";

// ✅ CORRECT: Fix the actual issue
interface SomeFunctionResult {
  // ... define the shape
}
const result: SomeFunctionResult = someUntypedFunction();
```

### REQUIRED BACKEND PRACTICES:

#### 1. Explicit Return Types

```typescript
// ❌ BAD
function calculate(a: number, b: number) {
  return a + b;
}

// ✅ GOOD
function calculate(a: number, b: number): number {
  return a + b;
}

// ✅ GOOD - async functions
async function fetchUser(id: string): Promise<User> {
  // ...
}
```

#### 2. Proper Error Handling — Try-Catch Decision Framework

**The golden rule:** Every catch block must DO something. Empty catches are bugs.

**Decision tree — when you write a try-catch, ask:**

1. **Is this a user-facing operation?** (API request, form submit, admin action)
   → Let the error propagate. The caller (resolver, controller, UI form) handles user feedback.
   → **Do NOT wrap in try-catch** unless you need cleanup (finally).

2. **Is this a secondary/optional side-effect?** (send email, cache write, analytics)
   → `catch (error) { this.logger.warn('...', error); }` — log and continue.
   → The primary operation must still succeed.

3. **Is this infrastructure setup?** (create index, initialize connection, warmup cache)
   → `catch (error) { this.logger.warn('...', error); }` — log degraded state.

4. **Is this a security validation returning boolean?** (validate token, check URL)
   → `catch { return false; }` — deny on error is the correct safe default.

5. **Is this a parser with a fallback?** (JSON.parse, URL constructor, date parsing)
   → `catch { return defaultValue; }` — only if a sensible default exists.

```typescript
// ❌ FORBIDDEN — empty catch (silent failure)
try {
  await updateUserProfile(userId, data);
} catch {
  // Don't fail if profile update fails
}

// ❌ FORBIDDEN — catch with only a comment
try {
  await sendWelcomeEmail(user);
} catch {
  // Error handling could be added here if needed
}

// ❌ BAD — console.log in backend
try {
  await someOperation();
} catch (e) {
  console.log(e);
}

// ✅ CORRECT — user-facing: no try-catch, let it propagate
const video = await this.videoRepository.findById(contentId);
const duration = video?.getDuration(); // null-check handles "not found"
// If DB is down, the error propagates to the resolver → user sees error

// ✅ CORRECT — secondary side-effect: log and continue
try {
  await this.emailService.sendWelcomeEmail(user);
} catch (error) {
  this.logger.warn(`Failed to send welcome email for user ${user.id}`, error);
}

// ✅ CORRECT — re-throw with context
try {
  await someOperation();
} catch (error) {
  if (error instanceof Error) {
    this.logger.error('Operation failed', { error: error.message });
    throw new ServiceException('Operation failed', error);
  }
  throw error;
}

// ✅ CORRECT — security validation: deny on error
isOriginAllowed(origin: string): boolean {
  try {
    const url = new URL(origin);
    return this.allowedOrigins.has(url.origin);
  } catch {
    return false;
  }
}

// ✅ CORRECT — parser with sensible default
function parseJSON<T>(raw: string, fallback: T): T {
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}
```

**Frontend-specific (React/Admin):**
- GraphQL mutation errors → use Apollo `onError` callback or catch + `toast.error()`
- Never silently swallow form submission errors — the user must see feedback
- Don't wrap in try-catch if the parent already handles via `onError`

#### 3. Dependency Injection Pattern

Use standard NestJS `@Injectable()` decorator with manual `@Inject()` for interface tokens.

```typescript
// ✅ CORRECT - Standard NestJS DI
@Injectable()
export class PaymentApplicationService {
  constructor(
    @Inject(RepositoryTokens.Payment()) private readonly paymentRepository: IPaymentRepository,
    @Inject(ServiceTokens.User()) private readonly userService: IUserService,
    @InjectModel(Payment.name) private model: Model<Payment>,
  ) {}
}

// ✅ CORRECT - Concrete class injection (no @Inject needed)
@Injectable()
export class VimeoSyncService {
  constructor(
    private readonly vimeoService: VimeoService,  // Concrete class - auto-resolved
    private readonly commandBus: CommandBus,
  ) {}
}
```

**Key Rules:**
- Use `@Injectable()` for all services
- Use `@Inject()` with tokens for interface dependencies
- Concrete classes can be injected directly without tokens
- Use token utilities from `@/shared/di` (RepositoryTokens, ServiceTokens, MapperTokens)

#### 4. DTO Validation

```typescript
// ❌ BAD
class CreateUserDto {
  email: string;
  password: string;
}

// ✅ GOOD
import { IsEmail, IsString, MinLength } from "class-validator";

class CreateUserDto {
  @IsEmail()
  email: string;

  @IsString()
  @MinLength(8)
  password: string;

  /**
   * 🚨 DTO INITIALIZATION RULE
   * ALWAYS use the definite assignment assertion (!:) for required properties.
   * NEVER use 'declare' (ambient) or default initializers.
   * This ensures properties are NOT stripped during JS compilation,
   * which is required for framework reflection (NestJS/GraphQL decorators) to work correctly.
   */
  @IsString()
  exampleField!: string;
}
```

### TYPESCRIPT ENFORCEMENT:

TypeScript rules are strictly enforced in this codebase. 4. **NO EXCEPTIONS for "quick fixes" or "temporary" code**

### WHEN WORKING IN BACKEND:

Before writing ANY backend code:

1. ✅ Check if proper types exist
2. ✅ Create interfaces/types if missing
3. ✅ Use type guards for runtime validation
4. ✅ Ensure all function signatures have return types
5. ✅ Never suppress TypeScript or Biome errors

### BACKEND TYPING EXAMPLES:

```typescript
// Repository pattern with proper types
interface UserRepository {
  findById(id: string): Promise<User | null>;
  create(data: CreateUserDto): Promise<User>;
  update(id: string, data: UpdateUserDto): Promise<User>;
}

// Service with proper injection
@Injectable()
export class UserService {
  constructor(
    @InjectModel(User.name)
    private readonly userModel: Model<UserDocument>,
    @Inject(CACHE_MANAGER)
    private readonly cacheManager: Cache
  ) {}

  async findUser(id: string): Promise<User> {
    const user = await this.userModel.findById(id);
    if (!user) {
      throw new NotFoundException(`User ${id} not found`);
    }
    return user;
  }
}

// Controller with proper validation
@Controller("users")
export class UserController {
  constructor(private readonly userService: UserService) {}

  @Post()
  @UsePipes(ValidationPipe)
  async create(@Body() dto: CreateUserDto): Promise<UserResponseDto> {
    const user = await this.userService.create(dto);
    return UserResponseDto.fromEntity(user);
  }
}
```

## 📄 PAGINATION RULES - CURSOR-BASED ONLY

### PAGINATION FORBIDDEN PATTERNS:

#### 1. NO OFFSET/LIMIT PAGINATION

- ❌ NEVER use `offset` in GraphQL inputs or DTOs
- ❌ NEVER use `skip()` in application/presentation layers
- ❌ NEVER expose limit/offset patterns in APIs
- ✅ ALWAYS use cursor-based pagination

```typescript
// ❌ FORBIDDEN - Offset-based pagination
@InputType()
export class GetUsersInput {
  @Field(() => Int)
  limit: number;

  @Field(() => Int)
  offset: number; // NEVER DO THIS
}

// ✅ CORRECT - Cursor-based pagination
@InputType()
export class GetUsersInput {
  @Field(() => String, { nullable: true })
  cursor?: string;

  @Field(() => Int, { defaultValue: 20 })
  limit: number;
}
```

#### 2. PROPER PAGINATION RESPONSE

```typescript
// ❌ FORBIDDEN - Offset in response
export interface GetUsersDto {
  users: User[];
  total: number;
  offset: number; // NEVER
  limit: number;
}

// ✅ CORRECT - Cursor-based response
export interface PaginatedResult<T> {
  items: T[];
  nextCursor: string | null;
  hasMore: boolean;
}
```

#### 3. REPOSITORY MUST USE PROPER INHERITANCE

All repositories MUST extend the appropriate base repository based on their aggregate pattern:

```typescript
// ❌ FORBIDDEN - Custom pagination implementation
async findUsers(limit: number, offset: number) {
  return this.model.find().skip(offset).limit(limit);
}

// ✅ CORRECT - Extend appropriate base repository
export class UserRepository extends WorkflowRepository<UserAggregate, UserDocument> {
  // findWithCursor inherited from CommonRepository base
}

export class CourseRepository extends ContentRepository<CourseAggregate, CourseDocument> {
  // Content-specific methods + cursor pagination inherited
}

export class BookmarkRepository extends CommonRepository<BookmarkAggregate, CommonDocument> {
  // Basic CRUD + cursor pagination inherited
}
```

**Repository Inheritance Rules:**

- **CommonRepository**: Simple entities (Bookmark, Comment, Progress)
- **CommonTitledRepository**: Entities with title/description only
- **WorkflowRepository**: Entities with workflow states (User, Booking, Conversation)
- **WorkflowTitledRepository**: Workflow + title/description (Milestone, Video, FEATURE_FLAG)
- **ContentRepository**: Full content entities (Course, Channel, DiscountDeal)
- **EventRepository**: Event-based entities (LiveEvent, MentorshipEvent)
- **ReviewableRepository**: Reviewable content (Post, Scenario)

See [inheritance guide](/docs/architecture/inheritance-guide.md) for complete mapping.

#### 4. NO DIRECT MONGODB SKIP IN APPLICATION LAYER

```typescript
// ❌ FORBIDDEN in application/presentation layers
const users = await this.model.find().skip(20).limit(10);

// ✅ CORRECT - Use repository methods
const result = await this.userRepository.findWithCursor(filters, {
  cursor,
  limit,
});
```

### PAGINATION STANDARDS:

1. **All repositories MUST extend appropriate base repository** which provides `findWithCursor`
2. **GraphQL inputs use `cursor` and `limit` only** (never offset)
3. **Responses return `nextCursor` and `hasMore`** (never total count)
4. **Internal implementation may use skip()** but ONLY within base repository classes
5. **Services use PaginationOptions interface** from core domain

```typescript
// Standard pagination options
interface PaginationOptions {
  cursor?: string;
  limit?: number;
  sortBy?: string;
  sortOrder?: "ASC" | "DESC";
}
```

### WHY CURSOR-BASED PAGINATION:

1. **Performance**: No need to skip large numbers of records
2. **Consistency**: Results remain stable even with concurrent inserts/deletes
3. **Scalability**: Works efficiently with large datasets
4. **User Experience**: No "jumping" pages when data changes

## 🎯 BACKEND TYPE SAFETY GOAL: 100%

Every line of backend code should be:

- Fully typed with no `any`
- Free of type assertions (`as`)
- Using proper type guards for runtime checks
- Following NestJS best practices
- Validated at runtime boundaries

**Remember: TypeScript exists to catch errors at compile time. Don't bypass it!**

## 📦 Package Manager Rules

- **ONLY use pnpm** for all package management
- Never use npm, npx, or yarn commands
- Use `pnpm` instead of `npm`
- Use `pnpx` instead of `npx`
- This is a turborepo project managed with pnpm workspaces

### pnpm Configuration Standards

- **Development**: Use `prefer-offline=true` for faster installs
- **CI/Production**: Use `--frozen-lockfile` flag
- **Scripts**:
  - `pnpm ci`: Full CI pipeline with frozen lockfile
  - `pnpm build:ci`: Production build with frozen lockfile
  - `pnpm test:ci`: Tests with frozen lockfile

### Common pnpm Commands

- Install dependencies: `pnpm install`
- Run scripts: `pnpm run [script]` or `pnpm [script]`
- Add packages: `pnpm add [package]`
- Execute binaries: `pnpx [command]`
- Workspace commands: `pnpm --filter=[workspace] [command]`
- CI install: `pnpm install --frozen-lockfile`

## 💻 Development Rules

### Before Starting Work

- Always run `pnpm install` and `docker-compose up -d`
- After pulling changes: Run `pnpm install` if package.json was modified

### When Adding Features

- Check existing patterns in similar modules
- Follow existing code patterns
- Test your changes before committing

### For GraphQL Changes

- Remember to run `pnpm codegen`

### For Debugging

- Check Docker logs with `docker-compose logs -f [service]`

### Testing Approach

- Write tests alongside your code (`.spec.ts` files)
- **NEVER** assume specific test framework or test script
- Check the README or search codebase to determine the testing approach

### Playwright Testing Rules

**data-testid Selector Usage:**

- **DO**: Use `page.getByTestId()` or page object locators
- **DON'T**: Use `page.waitForSelector('[data-testid="..."]')`

```typescript
// ✅ CORRECT
await page.getByTestId(DataTestIds.DASHBOARD.WELCOME_TITLE).waitFor();
await dashboardPage.welcomeTitle.waitFor({ state: "visible" });

// ❌ WRONG
await page.waitForSelector(
  `[data-testid="${DataTestIds.DASHBOARD.WELCOME_TITLE}"]`
);
```

**Waiting for Page Ready:**

- **DO**: Wait for specific elements or conditions
- **DON'T**: Use `waitForLoadState('networkidle')`

```typescript
// ✅ CORRECT - Wait for specific content
await dashboardPage.welcomeTitle.waitFor({ state: "visible" });

// ❌ WRONG - Waits for ALL network activity
await page.waitForLoadState("networkidle");
```

### After Completing Tasks

- **MUST** run `pnpm fixme` after completing a significant chunk of work (new feature, multi-file refactor, major bug fix). This auto-fixes lint/format, rebuilds shared packages, and runs typecheck in one command. Do NOT run after every small edit.
- If unable to find the correct command, ask for it and suggest writing it to CLAUDE.md

## 🎨 Code Style Rules

### File Naming Conventions ✅ (Updated October 2025)

**ALL FILES AND DIRECTORIES**: Use `kebab-case`

- **React Component Files**: `kebab-case` (e.g., `user-profile.tsx`, `button.tsx`)
- **Page Directories**: `kebab-case` (e.g., `student-dashboard/`, `live-event/`)
- **Utilities**: `kebab-case` (e.g., `auth-utils.ts`, `string-utils.ts`)
- **Hooks**: `kebab-case` (e.g., `use-auth.ts`, `use-categories.ts`)
- **Types**: `kebab-case` (e.g., `user-types.ts`, `api-types.ts`)
- **Entry Points**: Keep as `index.ts` or `main.ts`
- **Test Files**: Match source file name with `.spec.ts` or `.test.ts` suffix

**Code Naming (exports from files remain unchanged)**:

- **Component Names**: `PascalCase` (e.g., `export function UserProfile()`)
- **Function Names**: `camelCase` (e.g., `export function validateAuth()`)
- **Hook Names**: `camelCase` (e.g., `export function useAuth()`)
- **Constants**: `UPPER_SNAKE_CASE` (e.g., `export const API_URL`)

**Rationale**:

- **Single rule**: No mental overhead deciding between PascalCase and kebab-case
- **Cross-platform safety**: Eliminates case-sensitivity bugs on different operating systems
- **Git compatibility**: Prevents case-change issues in version control
- **Ecosystem consistency**: Matches npm packages and modern framework conventions (Next.js)
- **Better file grouping**: Related files sort together alphabetically

#### Examples:

- ✅ `components/user-profile.tsx` → `export function UserProfile()`
- ✅ `components/button.tsx` → `export function Button()`
- ✅ `pages/student-dashboard/` (directory)
- ✅ `pages/live-event/` (directory)
- ✅ `utils/auth-utils.ts` → `export function validateAuth()`
- ✅ `hooks/use-categories.ts` → `export function useCategories()`
- ✅ `types/user-types.ts` → `export interface UserProfile`
- ✅ `constants/api-endpoints.ts` → `export const API_URL`
- ❌ `components/UserProfile.tsx` (should be kebab-case)
- ❌ `pages/StudentDashboard/` (should be kebab-case)
- ❌ `utils/authUtils.ts` (should be kebab-case)
- ❌ `hooks/useAuth.ts` (should be kebab-case)

> **Migration Notes**:
>
> - June 2025: 125+ non-component files migrated from camelCase to kebab-case
> - October 2025: All pages and directories migrated to kebab-case for full consistency

### React

- **No explicit React imports**: Don't use `import React from 'react'`. Modern React with the new JSX transform doesn't require it.

### Imports

- **Use path aliases**: Prefer `@/components/...` or `@repo/...` imports over relative paths like `../../../components/...`

### Import Sorting Rules ✅ (Updated January 2025)

The project uses Biome to enforce consistent import ordering across all files.

#### Import Order (All Files)

Imports are automatically sorted into the following groups:

1. **'use' directives** (React/Next.js only) - `'use client'`, `'use server'`
2. **Node.js built-ins** - `node:fs`, `path`, `crypto`, etc.
3. **External packages** - `react`, `@mui/material`, `lodash`, etc.
4. **Internal monorepo packages** - `@repo/ui`, `@app/common`, etc.
5. **Side effect imports** - `import './styles.css'`
6. **Parent imports** - `../utils`, `../../components`
7. **Sibling imports** - `./helper`, `./types`
8. **Style imports** - `*.css`, `*.scss`, `*.module.scss`

#### Example Import Structure

```typescript
"use client"; // Next.js directive

// Node built-ins
import fs from "node:fs";
import path from "node:path";

// External packages
import React, { useState } from "react";
import { Button } from "@mui/material";
import clsx from "clsx";

// Internal monorepo packages (separated from external!)
import type { User } from "@repo/common";
import { useAuth } from "@repo/ui";
import { TextField } from "@app/shared";

// Parent imports
import { formatDate } from "../utils";

// Sibling imports
import { UserCard } from "./UserCard";
import { useUserData } from "./use-user-data";

// Styles (always last)
import styles from "./user-profile.module.scss";
```

#### Key Changes (January 2025)

- **@repo/_ and @app/_ packages are now separated from external packages** - Internal monorepo packages have their own group
- **NestJS apps now have structured imports** - Previously used default sorting without groups
- **Blank line required after all imports** - Enforced by `import/newline-after-import` rule

#### Auto-fixing Imports

- Run `pnpm biome check --write` to automatically sort imports in all files
- Pre-commit hooks will auto-fix import sorting before commits
- VS Code with Biome extension will auto-fix on save

### Libraries and Frameworks

- Check package.json before using libraries
- Verify library usage in existing codebase
- When creating new components, first look at existing components for patterns
- When editing code, look at surrounding context (especially imports) to understand framework choices

## 📐 Code Formatting Rules

**CRITICAL**: All code MUST match the project's Biome configuration exactly.

### Active Biome Configuration

See `biome.json` for the complete configuration. Key formatting rules:

- **Single quotes**: Use `'single quotes'` not `"double quotes"`
- **Arrow parentheses**: As needed (parens for multi-param, none for single param)
- **Line endings**: LF (Unix)
- **Semicolons**: Always required
- **Indentation**: 2 spaces (tab width 2)
- **Line width**: 120 characters
- **Trailing commas**: Always (including function params)

### Biome Linting Rules

- No unused imports or variables
- Prefer `const` over `let` when possible
- Use `type` imports for TypeScript types: `import type { User } from './types'`
- Destructure objects when accessing multiple properties
- No console.log in production code (except for debugging)
- **NEVER use `any` types** - always use proper TypeScript types (Window, NodeJS.Process, etc.)

### Import/Export Pattern Standards ✅ (Updated June 2025)

**CRITICAL**: The codebase has been migrated from default exports to named exports for all local files. This migration was completed in June 2025 to improve consistency, IDE support, and tree-shaking.

#### Export Standards

**React Components**: Use `export function` (NEVER default export)

```typescript
// ✅ Correct - Named export with function declaration
export function ComponentName(props: Props) {
  return <div>...</div>;
}

// ❌ Incorrect - Default export
export default function ComponentName(props: Props) {
  return <div>...</div>;
}

// ❌ Incorrect - Arrow function export
export const ComponentName = (props: Props) => {
  return <div>...</div>;
};
```

**React Hooks**: Use `export const` (arrow function)

```typescript
// ✅ Correct - Hooks use arrow functions with named export
export const useCustomHook = () => {
  // hook logic
};

// ❌ Incorrect - Default export for hooks
export default function useCustomHook() {
  // hook logic
}
```

**Utility Functions**: Use `export function`

```typescript
// ✅ Correct - Named export function
export function calculateTotal(items: Item[]): number {
  return items.reduce((sum, item) => sum + item.price, 0);
}

// ❌ Incorrect - Default export
export default function calculateTotal(items: Item[]): number {
  return items.reduce((sum, item) => sum + item.price, 0);
}
```

**Constants/Configurations**: Use `export const`

```typescript
// ✅ Correct - Named export constants
export const API_ENDPOINTS = {
  users: "/api/users",
  products: "/api/products",
};

// ❌ Incorrect - Default export for constants
const API_ENDPOINTS = {
  /* ... */
};
export default API_ENDPOINTS;
```

#### Import Standards

**Local Components/Files**: Always use named imports with curly braces

```typescript
// ✅ Correct - Named imports for local files
import { ComponentName } from "./ComponentName";
import { useCustomHook } from "../hooks/use-custom-hook";
import { API_ENDPOINTS } from "../../constants/api-endpoints";

// ❌ Incorrect - Default imports for local files
import ComponentName from "./ComponentName";
import useCustomHook from "../hooks/use-custom-hook";
```

**External Libraries**: Use default imports only when the library exports as default

```typescript
// ✅ Correct - External libraries with default exports
import React from "react";
import clsx from "clsx";

// ✅ Correct - External libraries with named exports
import { Button, TextField } from "@mui/material";
import { useQuery, useMutation } from "@apollo/client";
```

#### Migration Notes (June 2025)

- **59 components** were migrated from `export default` to `export function/const`
- **All corresponding imports** updated from default to named import syntax
- **Benefits**: Better IDE support, explicit imports, improved tree-shaking, consistent patterns
- **Breaking Change**: Any external imports of these components must use named import syntax

#### Exception: External Dependencies

Only use default imports for external packages that export as default (React, date-fns, etc.). All local project files must use named exports/imports.

### Before Writing Code

1. **Match existing patterns** in the file you're editing
2. **Check spacing** around operators, brackets, and braces
3. **Verify import order** - typically: external deps, then @repo/\*, then relative
4. **Follow export pattern standards** - React components use `export function`

## 📝 Git & Version Control Rules

- **NEVER** commit changes unless explicitly asked to
- **NEVER** push to remote repository unless explicitly asked
- **NEVER** use git commands with the -i flag (interactive mode not supported)
- If no changes to commit, do not create an empty commit

## 🛠️ General Development Rules

### File Management

- **NEVER** create files unless absolutely necessary
- **ALWAYS** prefer editing existing files

### Node Modules

- Avoid deleting node_modules directories
- Use caution with dependency management

### Communication

- Focus on specific requests
- Provide honest technical feedback
- Challenge questionable approaches and suggest better alternatives when appropriate

## 🚨 CRITICAL: Output Verification & Silent Failures

### The Problem

Shell shims (`pnpm`, `npm`, `npx`, `.bin/*`) use `exec` which breaks stdout capture in Windows/Git Bash environments. Commands appear to succeed (exit code 0) but produce NO OUTPUT.

### HARD RULES

1. **Empty output is NEVER success** - If a command that should produce output returns nothing, this is a CRITICAL FAILURE. Stop and investigate immediately.

2. **Truncated output is a RED FLAG** - If output appears cut off, re-run with different approach before proceeding.

3. **MUST see actual verification** - Before claiming tests/lint passed:
   - Tests: Must see "X passed, Y failed" or equivalent
   - Lint: Must see error count or "no issues"
   - TypeScript: Must see "Found 0 errors" or actual error list
   - If you can't see this output, YOU DON'T KNOW IF IT PASSED

4. **When output fails, use direct node**:
   ```bash
   # Instead of: pnpm test
   node node_modules/jest/bin/jest.js

   # Instead of: pnpm biome check
   node node_modules/@biomejs/biome/bin/biome check

   # Instead of: pnpm tsc
   node node_modules/typescript/bin/tsc
   ```

5. **NEVER push without verified output** - If you cannot get command output working, STOP and tell the user. Do not assume success.

### Response Protocol

When output is empty or cut:
```
⚠️ CRITICAL: Command produced no output. This is NOT success.
- Command: [what you ran]
- Expected: [what output should look like]
- Action: Investigating with direct node invocation...
```

## "Make it WORK" not "Make it PASS"

### FORBIDDEN Shortcuts

- ❌ Deleting tests to make CI pass (unless test is genuinely obsolete AND you explain why)
- ❌ Adding `@ts-ignore` to hide type errors
- ❌ Using `any` to bypass type checking
- ❌ Suppressing lint rules without fixing underlying issue
- ❌ Assuming empty output means success

### Required Approach

- ✅ Understand WHY an error occurs before fixing
- ✅ Fix the root cause, not the symptom
- ✅ If a test is truly obsolete, explain WHY before deleting
- ✅ If you can't fix it, tell the user - don't hide it

## 🎭 CQRS Pattern Usage Guidelines

### When to Use CQRS (Command Query Responsibility Segregation)

**Use CQRS When:**

- Complex business logic spans multiple aggregates
- Events need to be published for domain event handling
- Asynchronous processing is required
- Audit trail or event sourcing is needed
- Query optimization/caching is beneficial
- Multiple systems need to react to changes

**Use Direct Service/Repository When:**

- Simple CRUD operations
- Single aggregate operations
- No event publishing needed
- Synchronous operations only
- Direct database queries suffice

### Implementation Examples

```typescript
// ✅ Good - Simple operation, use service directly
@Resolver()
export class UserResolver {
  constructor(private userService: UserService) {}

  @Mutation()
  async updateUserProfile(input: UpdateProfileInput) {
    return this.userService.updateProfile(input);
  }
}

// ✅ Good - Complex operation with events, use CQRS
@Resolver()
export class OrderResolver {
  constructor(private commandBus: CommandBus) {}

  @Mutation()
  async placeOrder(input: PlaceOrderInput) {
    // This triggers inventory checks, payment processing, notifications
    return this.commandBus.execute(new PlaceOrderCommand(input));
  }
}

// ❌ Bad - Over-engineering simple operations
@CommandHandler(GetUserByIdCommand) // Don't do this!
export class GetUserByIdHandler {
  async execute(command: GetUserByIdCommand) {
    return this.userRepository.findById(command.id); // Just call repo directly!
  }
}
```

### Migration Strategy

When simplifying handlers:

1. Identify handlers that only proxy to repositories
2. Move logic to services
3. Update resolvers to use services directly
4. Remove unnecessary command/query classes and handlers
5. Keep complex business logic in CQRS handlers

## 🏗️ Domain Object Inheritance Rules

### Inheritance Alignment

When creating domain objects, ensure consistent inheritance across all layers:

**1. Content Objects** (need title, description, categories, picture):

- Aggregate: extends `ContentAggregate`
- Repository: extends `ContentRepository`
- Schema: uses `contentPlugin` and `ContentDocument`

**2. Workflow Objects** (need states but no content properties):

- Aggregate: extends `WorkflowAggregate`
- Repository: extends `WorkflowRepository`
- Schema: uses `workflowPlugin` and `WorkflowDocument`

**3. Simple Objects** (just basic fields):

- Aggregate: extends `CommonAggregate`
- Repository: extends `CommonRepository`
- Schema: uses `commonPlugin` and `CommonDocument`

### Quick Decision Guide

```
Does your object need title, description, categories?
├─ YES → ContentAggregate
└─ NO → Does it need workflow states (DRAFT, PUBLISHED)?
        ├─ YES → WorkflowAggregate
        └─ NO → CommonAggregate
```

### Common Mistakes to Avoid

- ❌ Aggregate extends `WorkflowAggregate` but Repository extends `ContentRepository`
- ❌ Using `WorkflowDocument` when aggregate extends `ContentAggregate`
- ❌ Duplicating fields that are already inherited from base classes
- ❌ Using `ContentAggregate` when object doesn't need content properties

### Validation

Run the audit script to check for mismatches:

```bash
npx ts-node scripts/audit-inheritance.ts
```

See [`/docs/architecture/inheritance-guide.md`](./docs/architecture/inheritance-guide.md) for detailed guide.

## ⚡ Pre-commit Hook Configuration

Three modes available for commits:

- Full validation: `.lintstagedrc.js` (lint + typecheck per workspace)
- Fast mode: `.lintstagedrc.light.js` (lint only, recommended)
- Manual: `pnpm typecheck:staged` for targeted typecheck

Pre-push hook runs full validation before pushing.

To switch modes: `cp .lintstagedrc.light.js .lintstagedrc.js`

## 🚀 Most Used Commands

```bash
# Development
pnpm dev                          # Start all services
pnpm --filter @app/web dev     # Start specific service

# Testing & Quality
pnpm test                         # Run tests
pnpm lint                         # Run linting
pnpm typecheck                    # Type checking
pnpm typecheck:staged             # Type check only staged files

# Building
pnpm build                        # Build all packages

# Code Generation
pnpm turbo gen create-domain      # Generate new domain with modern patterns
pnpm create-domain                # Alias for above
```

## 🔑 Environment Variables

Key environment variables required:

- `NODE_ENV` - Development/production environment
- `DATABASE_URL` - MongoDB connection string
- `REDIS_URL` - Redis connection string
- `RABBITMQ_URL` - RabbitMQ connection string
- `JWT_SECRET` - JWT signing secret
- `VIMEO_*` - Vimeo API credentials for video streaming
- `GOOGLE_*` - Google OAuth credentials

## 📋 Quick Tips

1. Before starting work: Always run `pnpm install` and `pnpm docker-up`
2. When adding features: Check existing patterns in similar modules
3. For GraphQL changes: Remember to run `pnpm codegen`
4. For debugging: Check Docker logs with `docker-compose logs -f [service]`
5. Testing approach: Write tests alongside your code (`.spec.ts` files)
6. After pulling changes: Run `pnpm install` if package.json was modified
7. For faster commits: Use lightweight lint-staged mode
