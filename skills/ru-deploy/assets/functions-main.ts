// ru-deploy: патч системного роутера edge-функций (main).
//
// ЗАЧЕМ. Штатный main/index.ts из Supabase проверяет JWT ГЛОБАЛЬНО: либо токен
// нужен ВСЕМ функциям (VERIFY_JWT=true), либо НИКОМУ (false). Пометка
// `// verify_jwt = false` в коде конкретной функции этим роутером НЕ читается —
// это особенность self-hosted (в облачном Supabase так можно, здесь нет).
// Из-за этого публичный вебхук (например YooKassa, который зовётся без токена)
// при VERIFY_JWT=true получает 401 "Missing authorization header" и не работает.
//
// РЕШЕНИЕ. Этот роутер дополнительно читает переменную окружения PUBLIC_FUNCTIONS
// (имена функций через запятую). Для функций из этого списка проверка JWT
// пропускается, для всех остальных остаётся включённой. Так публичный вебхук
// работает без токена, а защита остальных функций сохраняется.
//
// Сделать функцию публичной = добавить её имя в PUBLIC_FUNCTIONS в
// /opt/supabase/docker/.env и перезапустить контейнер functions. Сам файл
// править больше не нужно. server-setup.sh ставит этот роутер автоматически и
// при повторном запуске (идемпотентно).

import * as jose from 'https://deno.land/x/jose@v4.14.4/index.ts'

console.log('main function started (ru-deploy: PUBLIC_FUNCTIONS aware)')

const JWT_SECRET = Deno.env.get('JWT_SECRET')
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')
const VERIFY_JWT = Deno.env.get('VERIFY_JWT') === 'true'
// Имена функций, для которых проверку JWT пропускаем (публичные вебхуки и т.п.).
// Пример в .env:  PUBLIC_FUNCTIONS=yookassa-webhook,health
const PUBLIC_FUNCTIONS = (Deno.env.get('PUBLIC_FUNCTIONS') ?? '')
  .split(',')
  .map((s) => s.trim())
  .filter((s) => s.length > 0)

// Create JWKS for ES256/RS256 tokens (newer tokens)
let SUPABASE_JWT_KEYS: ReturnType<typeof jose.createRemoteJWKSet> | null = null
if (SUPABASE_URL) {
  try {
    SUPABASE_JWT_KEYS = jose.createRemoteJWKSet(
      new URL('/auth/v1/.well-known/jwks.json', SUPABASE_URL)
    )
  } catch (e) {
    console.error('Failed to fetch JWKS from SUPABASE_URL:', e)
  }
}

function getAuthToken(req: Request) {
  const authHeader = req.headers.get('authorization')
  if (!authHeader) {
    throw new Error('Missing authorization header')
  }
  const [bearer, token] = authHeader.split(' ')
  if (bearer !== 'Bearer') {
    throw new Error(`Auth header is not 'Bearer {token}'`)
  }
  return token
}

async function isValidLegacyJWT(jwt: string): Promise<boolean> {
  if (!JWT_SECRET) {
    console.error('JWT_SECRET not available for HS256 token verification')
    return false
  }
  const encoder = new TextEncoder()
  const secretKey = encoder.encode(JWT_SECRET)
  try {
    await jose.jwtVerify(jwt, secretKey)
  } catch (e) {
    console.error('Symmetric Legacy JWT verification error', e)
    return false
  }
  return true
}

async function isValidJWT(jwt: string): Promise<boolean> {
  if (!SUPABASE_JWT_KEYS) {
    console.error('JWKS not available for ES256/RS256 token verification')
    return false
  }
  try {
    await jose.jwtVerify(jwt, SUPABASE_JWT_KEYS)
  } catch (e) {
    console.error('Asymmetric JWT verification error', e)
    return false
  }
  return true
}

async function isValidHybridJWT(jwt: string): Promise<boolean> {
  const { alg: jwtAlgorithm } = jose.decodeProtectedHeader(jwt)
  if (jwtAlgorithm === 'HS256') {
    return await isValidLegacyJWT(jwt)
  }
  if (jwtAlgorithm === 'ES256' || jwtAlgorithm === 'RS256') {
    return await isValidJWT(jwt)
  }
  return false
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url)
  const { pathname } = url
  const path_parts = pathname.split('/')
  const service_name = path_parts[1]

  // Публичные функции (из PUBLIC_FUNCTIONS) пропускаем мимо проверки JWT.
  const isPublic = service_name && PUBLIC_FUNCTIONS.includes(service_name)

  if (req.method !== 'OPTIONS' && VERIFY_JWT && !isPublic) {
    try {
      const token = getAuthToken(req)
      const valid = await isValidHybridJWT(token)
      if (!valid) {
        return new Response(JSON.stringify({ msg: 'Invalid JWT' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        })
      }
    } catch (e) {
      console.error(e)
      return new Response(JSON.stringify({ msg: e.toString() }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      })
    }
  }

  if (!service_name || service_name === '') {
    const error = { msg: 'missing function name in request' }
    return new Response(JSON.stringify(error), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const servicePath = `/home/deno/functions/${service_name}`
  console.error(`serving the request with ${servicePath}`)

  const memoryLimitMb = 150
  const workerTimeoutMs = 1 * 60 * 1000
  const noModuleCache = false
  const importMapPath = null
  const envVarsObj = Deno.env.toObject()
  const envVars = Object.keys(envVarsObj).map((k) => [k, envVarsObj[k]])

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath,
      memoryLimitMb,
      workerTimeoutMs,
      noModuleCache,
      importMapPath,
      envVars,
    })
    return await worker.fetch(req)
  } catch (e) {
    const error = { msg: e.toString() }
    return new Response(JSON.stringify(error), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})
