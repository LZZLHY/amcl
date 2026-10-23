/* 使用交付补丁内的真实纯整数辅助函数，断言边界与已知期望；没有替身式 Draw 实现。 */
#include "draw_math.h"
int main(void) {
    uint32_t value;
    if(!amcl_index_add(65535,1,&value)||value!=65536) return 1;
    if(!amcl_index_add(70000,-5,&value)||value!=69995) return 2;
    if(amcl_index_add(1,-2,&value)) return 3;
    if(!amcl_index_add(UINT32_MAX,1,&value)||value!=0) return 4;
    if(!amcl_index_add(0,INT32_MAX,&value)||value!=INT32_MAX) return 5;
    if(!amcl_index_add(UINT32_MAX,INT32_MIN,&value)||value!=INT32_MAX) return 6;
    if(!amcl_buffer_fits(24,0,6,4)||amcl_buffer_fits(24,1,6,4)) return 7;
    if(!amcl_buffer_fits(SIZE_MAX,SIZE_MAX-3,3,1)) return 8;
    if(amcl_buffer_fits(SIZE_MAX,SIZE_MAX-3,4,1)) return 9;
    if(amcl_buffer_fits(24,25,0,4)||amcl_buffer_fits(24,0,1,0)) return 10;
    if(!amcl_vertex_fits(96,0,11,8,8)||amcl_vertex_fits(96,0,12,8,8)) return 11;
    if(!amcl_vertex_fits(SIZE_MAX,0,UINT32_MAX,16,8)) return 12;
    if(amcl_vertex_fits(16,SIZE_MAX,0,4,4)) return 13;
    if(amcl_vertex_fits(16,0,0,0,4)) return 14;
    return 0;
}
