#include "uniform_initializer_core.h"

#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

int g_checks = 0;

void Require(bool condition, const char* message) {
    ++g_checks;
    if (condition) return;
    std::cerr << "mg_glsl_uniform_initializer_core_test: FAIL: " << message << '\n';
    std::exit(1);
}

void RequireEqual(const std::string& actual, const std::string& expected, const char* message) {
    ++g_checks;
    if (actual == expected) return;
    std::cerr << "mg_glsl_uniform_initializer_core_test: FAIL: " << message << "\n--- expected ---\n"
              << expected << "\n--- actual ---\n"
              << actual << "\n----------------\n";
    std::exit(1);
}

// ---------------------------------------------------------------------------
// The implementation this pass replaced, copied so the fixtures can be proved
// to cover the actual defect
// ---------------------------------------------------------------------------
// A test that only shows the new code behaving well proves nothing about the
// bug: a fixture that the old code also handled correctly would pass just as
// happily. So the corruption is reproduced here, from the previous algorithm,
// and asserted. If the copy below ever stops producing the broken shape, the
// fixture has drifted away from the defect and the regression test above it is
// worthless.
//
// Faithful to the original in the two respects that matter: `uniform` is matched
// as a substring at any character position, and a declaration is deemed to have
// an initializer if any `=` appears before the next `;`. The character
// classification is spelled out rather than taken from <cctype> only to keep the
// host build warning-clean; every fixture here is ASCII, so the behaviour is the
// same.
bool LegacyIsSpace(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

bool LegacyIsNameChar(char c) {
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

std::string LegacyProcessUniformDeclarations(const std::string& glslCode) {
    std::string result;
    std::size_t scan_pos = 0;
    std::size_t chunk_start = 0;
    const std::size_t length = glslCode.length();
    const char* const precision_kws[] = {"highp", "lowp", "mediump"};
    const std::size_t precision_lens[] = {5, 4, 7};

    result.reserve(glslCode.length());

    while (scan_pos < length) {
        if (glslCode.compare(scan_pos, 7, "uniform") == 0) {
            if (scan_pos > chunk_start) {
                result.append(glslCode, chunk_start, scan_pos - chunk_start);
            }

            const std::size_t decl_start = scan_pos;
            scan_pos += 7;

            std::string precision;
            std::string type;
            bool found_precision = false;

            while (scan_pos < length) {
                while (scan_pos < length && LegacyIsSpace(glslCode[scan_pos])) ++scan_pos;

                for (std::size_t k = 0; k < 3; ++k) {
                    if (glslCode.compare(scan_pos, precision_lens[k], precision_kws[k]) == 0) {
                        precision = std::string(" ") + precision_kws[k];
                        scan_pos += precision_lens[k];
                        found_precision = true;
                        break;
                    }
                }
                if (found_precision) break;

                const std::size_t type_start = scan_pos;
                while (scan_pos < length && LegacyIsNameChar(glslCode[scan_pos])) ++scan_pos;
                type = glslCode.substr(type_start, scan_pos - type_start);
                break;
            }

            while (scan_pos < length) {
                while (scan_pos < length && LegacyIsSpace(glslCode[scan_pos])) ++scan_pos;

                bool found = false;
                for (std::size_t k = 0; k < 3; ++k) {
                    if (glslCode.compare(scan_pos, precision_lens[k], precision_kws[k]) == 0) {
                        if (precision.empty()) precision = std::string(" ") + precision_kws[k];
                        scan_pos += precision_lens[k];
                        found = true;
                        break;
                    }
                }
                if (!found) break;
            }

            if (type.empty()) {
                const std::size_t type_start = scan_pos;
                while (scan_pos < length && LegacyIsNameChar(glslCode[scan_pos])) ++scan_pos;
                type = glslCode.substr(type_start, scan_pos - type_start);
            }

            while (scan_pos < length && LegacyIsSpace(glslCode[scan_pos])) ++scan_pos;
            const std::size_t name_start = scan_pos;
            while (scan_pos < length && LegacyIsNameChar(glslCode[scan_pos])) ++scan_pos;
            const std::string name = glslCode.substr(name_start, scan_pos - name_start);

            std::size_t decl_end = glslCode.find(';', scan_pos);
            if (decl_end == std::string::npos)
                decl_end = length;
            else
                ++decl_end;
            const bool has_initializer = (glslCode.find('=', scan_pos) < decl_end);
            if (has_initializer) {
                result.append("uniform").append(precision).append(" ").append(type).append(" ").append(name).append(
                    ";");
            } else {
                result.append(glslCode, decl_start, decl_end - decl_start);
            }

            scan_pos = chunk_start = decl_end;
        } else {
            ++scan_pos;
        }
    }

    if (chunk_start < length) {
        result.append(glslCode, chunk_start, length - chunk_start);
    }

    return result;
}

// The shape SPIRV-Cross emits for Minecraft 26.3 snapshot 9's terrain fragment
// shaders: a UBO instance called `_uniform_instance_00_01`, read in an `if`
// condition, with local declarations immediately inside the branch. Every
// element here is load bearing -- remove the `==`, the leading `_`, or the local
// declaration and the old algorithm no longer corrupts it.
const char* const kSnapshot9Branch =
    "void main()\n"
    "{\n"
    "    if (_uniform_instance_00_01.UseRgss == 1)\n"
    "    {\n"
    "        highp vec2 param = gl_FragCoord.xy;\n"
    "        highp vec2 param_2 = param;\n"
    "        fragColor = vec4(param_2, 0.0, 1.0);\n"
    "    }\n"
    "    else\n"
    "    {\n"
    "        fragColor = vec4(0.0);\n"
    "    }\n"
    "}\n";

void NegativeControl_LegacyReallyCorruptsTheFixture() {
    const std::string broken = LegacyProcessUniformDeclarations(kSnapshot9Branch);
    Require(broken.find("if (_uniform _instance_00_01 ;") != std::string::npos,
            "negative control: the previous implementation no longer produces the corrupted branch, so the fixture "
            "no longer covers the defect");
    Require(broken.find("highp vec2 param = gl_FragCoord.xy;") == std::string::npos,
            "negative control: the previous implementation should have swallowed the first local declaration");
    Require(broken.find("else") != std::string::npos,
            "negative control: the stray 'else' is part of the reported failure and must still be present");
    Require(broken != std::string(kSnapshot9Branch), "negative control: the previous implementation left the fixture "
                                                     "unchanged, which contradicts the reported failure");
}

void Snapshot9BranchIsLeftAlone() {
    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(kSnapshot9Branch);
    RequireEqual(r.code, std::string(kSnapshot9Branch), "snapshot 9 branch must pass through byte for byte");
    Require(r.stats.seen == 0, "there is no 'uniform' identifier token in the snapshot 9 branch, so none may be seen");
    Require(r.stats.stripped == 0, "nothing may be stripped from the snapshot 9 branch");
    Require(r.stats.unhandled() == 0, "the snapshot 9 branch contains no uniform declaration to decline");
}

void IdentifiersContainingTheKeywordAreNotTheKeyword() {
    const char* const cases[] = {
        "highp float x = _uniform_instance_00_01.a;\n",
        "bool b = nonuniform == 1;\n",
        "highp float u = uniformity = 2.0;\n",
        "highp float v = my_uniform = 3.0;\n",
        "highp float w = uniforms[0] = 4.0;\n",
        "highp float q = uniform0 = 5.0;\n",
    };
    for (const char* const text : cases) {
        const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(text);
        RequireEqual(r.code, std::string(text), "an identifier merely containing 'uniform' must be untouched");
        Require(r.stats.seen == 0, "an identifier merely containing 'uniform' is not a keyword token");
    }
}

void KeywordInsideCommentsAndDirectivesIsText() {
    const char* const cases[] = {
        "// uniform highp float a = 1.0;\n",
        "/* uniform highp float b = 2.0; */\n",
        "/*\n * uniform highp float c = 3.0;\n */\n",
        "#define FAKE uniform highp float d = 4.0;\n",
        "#define SPLIT uniform highp \\\n    float e = 5.0;\n",
        "int a; /* trailing */\n#define AFTER_COMMENT uniform highp float f = 6.0;\n",
        "// continued \\\nuniform highp float g = 7.0;\n",
    };
    for (const char* const text : cases) {
        const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(text);
        RequireEqual(r.code, std::string(text), "'uniform' inside a comment or a directive is not a declaration");
        Require(r.stats.seen == 0, "'uniform' inside a comment or a directive must not be seen as a token");
    }
}

void TheCompatibilityDutyStillHappens() {
    const mg::glsl::UniformInitializerRewrite r =
        mg::glsl::stripGlobalUniformInitializers("precision highp float;\n"
                                                "uniform highp float uAlpha = 1.0;\n"
                                                "void main() { fragColor = vec4(uAlpha); }\n");
    RequireEqual(r.code,
                 std::string("precision highp float;\n"
                             "uniform highp float uAlpha;\n"
                             "void main() { fragColor = vec4(uAlpha); }\n"),
                 "a real uniform initializer must be removed and nothing else");
    Require(r.stats.seen == 1, "one uniform keyword token expected");
    Require(r.stats.stripped == 1, "one initializer expected to be stripped");
    Require(r.stats.unhandled() == 0, "nothing should have been declined here");
}

void DeclarationsWithoutInitializersAreIdentity() {
    const char* const text = "uniform highp vec4 uColor;\n"
                             "uniform sampler2D Sampler0;\n"
                             "uniform highp mat4 uModelViewMat;\n";
    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(text);
    RequireEqual(r.code, std::string(text), "declarations already in ES form must not be rewritten");
    Require(r.stats.no_initializer == 3, "three initializer-free declarations expected");
    Require(r.stats.stripped == 0, "nothing to strip");
}

void ArraySuffixesAreSupported() {
    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(
        "uniform highp vec4 uArr[4] = vec4[4](vec4(0.0), vec4(1.0), vec4(2.0), vec4(3.0));\n"
        "uniform highp float uGrid[2][3] = float[2][3](float[3](0.0, 1.0, 2.0), float[3](3.0, 4.0, 5.0));\n");
    RequireEqual(r.code,
                 std::string("uniform highp vec4 uArr[4];\n"
                             "uniform highp float uGrid[2][3];\n"),
                 "array declarators keep their suffixes and lose only the initializer");
    Require(r.stats.stripped == 2, "two array initializers expected to be stripped");
}

// Commas belong to the initializer expression here, not to a second declarator.
// The distinction is the difference between stripping an initializer and
// deleting a variable.
void CommasInsideAnInitializerExpressionAreNotDeclarators() {
    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(
        "uniform highp vec4 uTint = vec4(1.0, 0.5, 0.25, 1.0);\n"
        "uniform highp mat2 uRot = mat2(vec2(1.0, 0.0), vec2(0.0, 1.0));\n");
    RequireEqual(r.code,
                 std::string("uniform highp vec4 uTint;\n"
                             "uniform highp mat2 uRot;\n"),
                 "commas nested inside the initializer must not end the declaration");
    Require(r.stats.stripped == 2, "both initializers expected to be stripped");
    Require(r.stats.unhandled() == 0, "neither declaration is a multi-declarator one");
}

void CommentBetweenDeclaratorAndEqualsIsPreserved() {
    const mg::glsl::UniformInitializerRewrite r =
        mg::glsl::stripGlobalUniformInitializers("uniform highp float a /* keep me */ = 1.0;\n");
    RequireEqual(r.code, std::string("uniform highp float a /* keep me */ ;\n"),
                 "a comment inside the declaration must survive the rewrite");
    Require(r.stats.stripped == 1, "the initializer should still have been removed");
}

void InterfaceBlocksAreDeclinedQuietly() {
    const char* const text = "layout(std140) uniform _uniform_instance_00_01_type\n"
                             "{\n"
                             "    int UseRgss;\n"
                             "    highp float Scale;\n"
                             "} _uniform_instance_00_01;\n";
    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(text);
    RequireEqual(r.code, std::string(text), "a uniform block must pass through unchanged");
    Require(r.stats.seen == 1, "the block's 'uniform' keyword is a token and must be counted");
    Require(r.stats.unhandled_interface_block == 1, "the block must be declined as an interface block");
    Require(r.stats.unhandled_with_initializer == 0,
            "uniform blocks are ubiquitous: reporting them as suspected initializers would make the warning useless");
}

void MultipleDeclaratorsAreDeclinedLoudly() {
    const char* const text = "uniform highp float a = 1.0, b = 2.0;\n";
    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(text);
    RequireEqual(r.code, std::string(text), "a multi-declarator uniform must not be half-rewritten");
    Require(r.stats.unhandled_multiple_declarators == 1, "expected the multiple-declarator outcome");
    Require(r.stats.unhandled_with_initializer == 1,
            "this one really does carry an initializer, so it must be reported");
}

void PreprocessorInsideADeclarationIsDeclined() {
    const char* const text = "uniform highp float a =\n"
                             "#ifdef FOO\n"
                             "    1.0\n"
                             "#else\n"
                             "    2.0\n"
                             "#endif\n"
                             ";\n";
    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(text);
    RequireEqual(r.code, std::string(text), "a declaration spanning directives must not be rewritten");
    Require(r.stats.unhandled_preprocessor == 1, "expected the preprocessor outcome, not a generic failure");
    Require(r.stats.unhandled_with_initializer == 1, "the declaration does carry an initializer");
}

void UnterminatedDeclarationIsDeclined() {
    const char* const text = "uniform highp float a = 1.0";
    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(text);
    RequireEqual(r.code, std::string(text), "a declaration with no terminating ';' must not be rewritten");
    Require(r.stats.unhandled_unterminated == 1, "expected the unterminated outcome");
}

void UnterminatedBlockCommentIsDeclined() {
    const char* const text = "uniform highp float a = 1.0;\n/* never closed\nuniform highp float b = 2.0;\n";
    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(text);
    RequireEqual(r.code,
                 std::string("uniform highp float a;\n/* never closed\nuniform highp float b = 2.0;\n"),
                 "text after an unterminated comment is comment, so only the first declaration is rewritten");
    Require(r.stats.stripped == 1, "only the declaration before the unterminated comment may be rewritten");
    Require(r.stats.seen == 1, "the 'uniform' inside the unterminated comment is not a token");
}

void KeywordInsideABlockOrParameterListIsNeverRewritten() {
    const char* const cases[] = {
        "void main()\n{\n    uniform highp float x = 1.0;\n}\n",
        "void f(uniform highp float x)\n{\n}\n",
        "highp float k[2] = float[2](uniform_a = 1.0, 2.0);\n",
    };
    const std::size_t expected_seen[] = {1, 1, 0};
    for (std::size_t k = 0; k < 3; ++k) {
        const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(cases[k]);
        RequireEqual(r.code, std::string(cases[k]), "a 'uniform' that is not at global scope must not be rewritten");
        Require(r.stats.seen == expected_seen[k], "unexpected keyword-token count outside global scope");
        Require(r.stats.stripped == 0, "nothing outside global scope may be stripped");
    }
    const mg::glsl::UniformInitializerRewrite in_block = mg::glsl::stripGlobalUniformInitializers(cases[0]);
    Require(in_block.stats.not_at_global_scope == 1, "the in-block keyword must be counted as out of scope");
    const mg::glsl::UniformInitializerRewrite in_params = mg::glsl::stripGlobalUniformInitializers(cases[1]);
    Require(in_params.stats.not_at_global_scope == 1, "the in-parameter-list keyword must be counted as out of scope");
}

// The whole translation unit, in the order and shape the reported failure had:
// UBO block, plain uniforms, one uniform that really does carry an initializer,
// and the branch that used to be destroyed.
void WholeShaderEndToEnd() {
    const std::string input = std::string("#version 320 es\n"
                                          "precision highp float;\n"
                                          "\n"
                                          "layout(std140) uniform _uniform_instance_00_01_type\n"
                                          "{\n"
                                          "    int UseRgss;\n"
                                          "} _uniform_instance_00_01;\n"
                                          "\n"
                                          "uniform sampler2D Sampler0;\n"
                                          "uniform highp float uFade = 0.5;\n"
                                          "\n"
                                          "layout(location = 0) out highp vec4 fragColor;\n"
                                          "\n") +
                              kSnapshot9Branch;
    const std::string expected = std::string("#version 320 es\n"
                                             "precision highp float;\n"
                                             "\n"
                                             "layout(std140) uniform _uniform_instance_00_01_type\n"
                                             "{\n"
                                             "    int UseRgss;\n"
                                             "} _uniform_instance_00_01;\n"
                                             "\n"
                                             "uniform sampler2D Sampler0;\n"
                                             "uniform highp float uFade;\n"
                                             "\n"
                                             "layout(location = 0) out highp vec4 fragColor;\n"
                                             "\n") +
                                 kSnapshot9Branch;

    const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(input);
    RequireEqual(r.code, expected, "end-to-end rewrite of a snapshot 9 shaped translation unit");
    Require(r.stats.seen == 3, "three uniform keyword tokens: the block, Sampler0 and uFade");
    Require(r.stats.stripped == 1, "only uFade carries an initializer");
    Require(r.stats.no_initializer == 1, "Sampler0 is already in ES form");
    Require(r.stats.unhandled_interface_block == 1, "the block is declined");
    Require(r.stats.unhandled_with_initializer == 0, "nothing here is left broken for the driver");

    // The four identifiers the driver complained about must all still be there.
    Require(r.code.find("_uniform_instance_00_01.UseRgss == 1") != std::string::npos,
            "the branch condition must survive");
    Require(r.code.find("highp vec2 param = gl_FragCoord.xy;") != std::string::npos,
            "the first local declaration must survive");
    Require(r.code.find("highp vec2 param_2 = param;") != std::string::npos,
            "the second local declaration must survive");
    Require(r.code.find("    else\n") != std::string::npos, "the else branch must keep its syntactic context");
    Require(r.code.find("if (_uniform _instance_") == std::string::npos,
            "the corrupted shape must not appear anywhere in the output");

    // Running the pass over its own output must change nothing further.
    const mg::glsl::UniformInitializerRewrite again = mg::glsl::stripGlobalUniformInitializers(r.code);
    RequireEqual(again.code, r.code, "the pass must be idempotent");
    Require(again.stats.stripped == 0, "a second run has nothing left to strip");
}

void DegenerateInputs() {
    const char* const cases[] = {"", "uniform", "uniform ", "uniform;", "uniform x;", "uniform =", "u", ";", "{}",
                                 "uniform highp float"};
    for (const char* const text : cases) {
        const mg::glsl::UniformInitializerRewrite r = mg::glsl::stripGlobalUniformInitializers(text);
        RequireEqual(r.code, std::string(text), "degenerate input must be returned unchanged");
        Require(r.stats.stripped == 0, "degenerate input must not be rewritten");
    }
}

} // namespace

int main() {
    NegativeControl_LegacyReallyCorruptsTheFixture();
    Snapshot9BranchIsLeftAlone();
    IdentifiersContainingTheKeywordAreNotTheKeyword();
    KeywordInsideCommentsAndDirectivesIsText();
    TheCompatibilityDutyStillHappens();
    DeclarationsWithoutInitializersAreIdentity();
    ArraySuffixesAreSupported();
    CommasInsideAnInitializerExpressionAreNotDeclarators();
    CommentBetweenDeclaratorAndEqualsIsPreserved();
    InterfaceBlocksAreDeclinedQuietly();
    MultipleDeclaratorsAreDeclinedLoudly();
    PreprocessorInsideADeclarationIsDeclined();
    UnterminatedDeclarationIsDeclined();
    UnterminatedBlockCommentIsDeclined();
    KeywordInsideABlockOrParameterListIsNeverRewritten();
    WholeShaderEndToEnd();
    DegenerateInputs();

    std::cout << "mg_glsl_uniform_initializer_core_test: PASS (" << g_checks << " checks)\n";
    return 0;
}
