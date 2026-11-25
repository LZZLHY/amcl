#pragma once

/* 私有 reader 的增量查询。generation 输入本消费者上次的游标（首次为零）；
 * 返回新游标与 connected 的变化槽位图，置位的槽须重新读取；路线撤销时位图为 -1。
 * 返回码专用，旧 reader 返回 0 或 -1，可走原位图协议。 */
enum { AMCL_GAMEPAD_QUERY_CHANGES = -3, AMCL_GAMEPAD_CHANGES_SUPPORTED = 3 };
