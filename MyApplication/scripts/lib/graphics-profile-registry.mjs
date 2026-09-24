import { stripComments } from './source-noise.mjs';

/** Parse the intentionally declarative ArkTS table, never execute source text. */
export function parseGraphicsRegistry(text) {
  const code = stripComments(text);
  const enums = new Map();
  for (const match of code.matchAll(/export\s+enum\s+(\w+)\s*\{([^}]+)\}/g)) {
    for (const member of match[2].matchAll(/(\w+)\s*=\s*'([^']*)'/g)) {
      enums.set(match[1] + '.' + member[1], member[2]);
    }
  }
  const declaration = /export\s+const\s+GRAPHICS_PROFILES\s*:\s*GraphicsProfileSpec\[\]\s*=\s*/.exec(code);
  if (!declaration) throw new Error('Cannot parse canonical GRAPHICS_PROFILES declaration');
  let pos = declaration.index + declaration[0].length;
  function skip() { while (/\s/.test(code[pos] || '') && pos < code.length) pos++; }
  function consume(character) {
    skip();
    if (code[pos++] !== character) throw new Error('Expected ' + character + ' at ' + (pos - 1));
  }
  function string() {
    const quote = code[pos++];
    let value = '';
    while (pos < code.length) {
      const c = code[pos++];
      if (c === quote) return value;
      if (c !== '\\') { value += c; continue; }
      const escaped = code[pos++];
      const replacements = { n: '\n', r: '\r', t: '\t', '\\': '\\', "'": "'", '"': '"' };
      if (!Object.hasOwn(replacements, escaped)) throw new Error('Unsupported registry string escape');
      value += replacements[escaped];
    }
    throw new Error('Unterminated registry string');
  }
  function identifier() {
    skip();
    const found = /^[A-Za-z_][A-Za-z0-9_.]*/.exec(code.slice(pos));
    if (!found) throw new Error('Expected registry identifier at ' + pos);
    pos += found[0].length;
    return found[0];
  }
  function value() {
    skip();
    const c = code[pos];
    if (c === "'" || c === '"') return string();
    if (c === '[') {
      pos++;
      const result = [];
      skip();
      while (code[pos] !== ']') {
        result.push(value());
        skip();
        if (code[pos] === ']') break;
        consume(',');
        skip();
      }
      consume(']');
      return result;
    }
    if (c === '{') {
      pos++;
      const result = {};
      skip();
      while (code[pos] !== '}') {
        const key = code[pos] === "'" || code[pos] === '"' ? string() : identifier();
        if (Object.hasOwn(result, key)) throw new Error('Duplicate registry field: ' + key);
        consume(':');
        result[key] = value();
        skip();
        if (code[pos] === '}') break;
        consume(',');
        skip();
      }
      consume('}');
      return result;
    }
    const name = identifier();
    if (name === 'true') return true;
    if (name === 'false') return false;
    if (enums.has(name)) return enums.get(name);
    throw new Error('Non-declarative or unknown registry value: ' + name);
  }
  const profiles = value();
  consume(';');
  if (!Array.isArray(profiles) || profiles.length === 0) throw new Error('Canonical profile table is empty');
  return profiles;
}

const quoted = (value) => JSON.stringify(value);
export function renderGraphicsProfileMirror(profiles) {
  const live = profiles.filter((profile) => profile.lifecycle !== 'retired');
  const defaultProfile = profiles.find((profile) => profile.selectionRole === 'default');
  if (!defaultProfile) throw new Error('Canonical default profile is absent');
  const requirementRows = live.map((p, index) => {
    const identities = [p.requirementId, ...(Array.isArray(p.requirementIds) ? p.requirementIds : [])]
      .filter((value, position, values) => typeof value === 'string' && values.indexOf(value) === position);
    // Keep the pointer elements const as well as the pointed-to strings. This
    // makes the generated array decay to `const char* const*`, which is the
    // metadata field type and is accepted by both clang and MSVC constexpr
    // aggregate initialization.
    return 'inline constexpr const char* const kGraphicsRequirements' + index + '[] = {'
      + identities.map(quoted).join(', ') + '};';
  }).join('\n');
  const rows = live.map((p, index) => '    {' + [
    p.id, p.api, p.nativeRoute, p.transport, p.requirementId,
  ].map(quoted).join(', ') + ', kGraphicsRequirements' + index + ', sizeof(kGraphicsRequirements' + index + ') / sizeof(kGraphicsRequirements' + index + '[0]), '
    + [p.admission, p.glLibName, p.capabilityKind].map(quoted).join(', ') + ', '
    + p.windowProviders.reduce((mask, provider) => mask | (provider === 'GLFW' ? 1 : provider === 'SDL3' ? 2 : 0), 0)
    + 'u, ' + p.platforms.reduce((mask, platform) => mask | (platform === 'MOBILE' ? 1 : platform === 'DESKTOP' ? 2 : 0), 0)
    + 'u, ' + p.systemLibrary + ', ' + [p.contextApi, p.glfwSharedContext, p.glfwAuxiliaryWindow,
      p.sdlAuxiliaryWindow, p.parkingContext].map(quoted).join(', ') + '},').join('\n');
  const legacy = live.filter((p) => p.api === 'OPENGL').map((p) =>
    '    {' + quoted(p.id) + ', ' + quoted(p.glLibName) + ', true, nullptr, ' + p.systemLibrary + '},').join('\n');
  return [
    '// Generated by scripts/generate-graphics-profile-mirror.mjs. Do not edit.',
    '// Source: launch/src/main/ets/GraphicsProfileRegistry.ets',
    '#ifndef AMCL_GRAPHICS_PROFILE_MIRROR_GENERATED_H',
    '#define AMCL_GRAPHICS_PROFILE_MIRROR_GENERATED_H',
    '#include <cstddef>',
    'namespace amcl { namespace graphics {',
    'struct GraphicsProfileMetadata {',
    '    const char* id;',
    '    const char* api;',
    '    const char* nativeRoute;',
    '    const char* transport;',
    '    const char* requirementId;',
    '    const char* const* requirementIds;',
    '    std::size_t requirementCount;',
    '    const char* admission;',
    '    const char* glLibName;',
    '    const char* capabilityKind;',
    '    unsigned providerMask;',
    '    unsigned platformMask;',
    '    bool systemLibrary;',
    '    // 与 ArkTS 同源的宿主能力；运行中的驱动准入仍独立执行。',
    '    const char* contextApi;',
    '    const char* glfwSharedContext;',
    '    const char* glfwAuxiliaryWindow;',
    '    const char* sdlAuxiliaryWindow;',
    '    const char* parkingContext;',
    '};',
    'inline constexpr const char* kDefaultGraphicsProfileId = ' + quoted(defaultProfile.id) + ';',
    requirementRows,
    'inline constexpr GraphicsProfileMetadata kGraphicsProfiles[] = {',
    rows,
    '};',
    'inline constexpr std::size_t kGraphicsProfileCount = sizeof(kGraphicsProfiles) / sizeof(kGraphicsProfiles[0]);',
    'constexpr bool GraphicsProfileStringEqual(const char* a, const char* b) {',
    '    if (a == nullptr || b == nullptr) return a == b;',
    "    while (*a != '\\0' && *a == *b) { ++a; ++b; }",
    '    return *a == *b;',
    '}',
    'constexpr const GraphicsProfileMetadata* FindGraphicsProfile(const char* id) {',
    '    for (std::size_t i = 0; i < kGraphicsProfileCount; ++i) {',
    '        if (GraphicsProfileStringEqual(id, kGraphicsProfiles[i].id)) return &kGraphicsProfiles[i];',
    '    }',
    '    return nullptr;',
    '}',
    'constexpr bool GraphicsProfileSupportsRequirement(const GraphicsProfileMetadata& profile, const char* requirement) {',
    '    if (requirement == nullptr) return false;',
    '    for (std::size_t i = 0; i < profile.requirementCount; ++i) {',
    '        if (GraphicsProfileStringEqual(requirement, profile.requirementIds[i])) return true;',
    '    }',
    '    return false;',
    '}',
    'constexpr bool GraphicsProfileSupportsProvider(const GraphicsProfileMetadata& profile, const char* provider) {',
    '    const unsigned mask = GraphicsProfileStringEqual(provider, "GLFW") ? 1u',
    '        : (GraphicsProfileStringEqual(provider, "SDL3") ? 2u : 0u);',
    '    return mask != 0u && (profile.providerMask & mask) != 0u;',
    '}',
    'constexpr bool GraphicsProfileSupportsPlatform(const GraphicsProfileMetadata& profile, const char* platform) {',
    '    const unsigned mask = GraphicsProfileStringEqual(platform, "MOBILE") ? 1u',
    '        : (GraphicsProfileStringEqual(platform, "DESKTOP") ? 2u : 0u);',
    '    return mask != 0u && (profile.platformMask & mask) != 0u;',
    '}',
    'struct GeneratedGlLibrary {',
    '    const char* id;',
    '    const char* glLibName;',
    '    bool availableInThisBuild;',
    '    const char* unavailableReason;',
    '    bool systemLibrary;',
    '};',
    '// Legacy API describes compiled routing support; artifact admission is checked separately.',
    'inline constexpr GeneratedGlLibrary kLegacyGlLibraries[] = {',
    legacy,
    '};',
    'constexpr bool GraphicsProfileMirrorValid() {',
    '    for (std::size_t i = 0; i < kGraphicsProfileCount; ++i) {',
    '        const auto& p = kGraphicsProfiles[i];',
    "        if (p.id[0] == '\\0' || p.providerMask == 0u || p.platformMask == 0u) return false;",
    '        const bool isGl = GraphicsProfileStringEqual(p.api, "OPENGL");',
    "        if (isGl == (p.glLibName[0] == '\\0')) return false;",
    '        for (std::size_t j = i + 1; j < kGraphicsProfileCount; ++j) {',
    '            if (GraphicsProfileStringEqual(p.id, kGraphicsProfiles[j].id)) return false;',
    '        }',
    '    }',
    '    return true;',
    '}',
    'static_assert(GraphicsProfileMirrorValid(), "invalid generated graphics profile mirror");',
    '} }',
    '#endif',
    '',
  ].join('\n');
}
