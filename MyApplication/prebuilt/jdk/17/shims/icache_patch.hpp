/*
 * Copyright (c) 1999, 2020, Oracle and/or its affiliates. All rights reserved.
 * Copyright (c) 2014, Red Hat Inc. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 *
 */

#ifndef OS_CPU_LINUX_AARCH64_ICACHE_AARCH64_HPP
#define OS_CPU_LINUX_AARCH64_ICACHE_AARCH64_HPP

#include <stdint.h>

// Inline __clear_cache for HarmonyOS (musl libc does not provide it)
class ICache : public AbstractICache {
 private:
  static void do_clear_cache(char* start, char* end) {
    static size_t ctr_el0 = 0;
    if (ctr_el0 == 0) {
      __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr_el0));
    }
    size_t dcache_line = 4 << ((ctr_el0 >> 16) & 0xf);
    size_t icache_line = 4 << ((ctr_el0 >> 0) & 0xf);
    char* p;
    for (p = (char*)((uintptr_t)start & ~(dcache_line - 1)); p < end; p += dcache_line) {
      __asm__ volatile("dc cvau, %0" :: "r"(p) : "memory");
    }
    __asm__ volatile("dsb ish" ::: "memory");
    for (p = (char*)((uintptr_t)start & ~(icache_line - 1)); p < end; p += icache_line) {
      __asm__ volatile("ic ivau, %0" :: "r"(p) : "memory");
    }
    __asm__ volatile("dsb ish" ::: "memory");
    __asm__ volatile("isb" ::: "memory");
  }
 public:
  static void initialize();
  static void invalidate_word(address addr) {
    do_clear_cache((char *)addr, (char *)(addr + 4));
  }
  static void invalidate_range(address start, int nbytes) {
    do_clear_cache((char *)start, (char *)(start + nbytes));
  }
};

#endif // OS_CPU_LINUX_AARCH64_ICACHE_AARCH64_HPP
