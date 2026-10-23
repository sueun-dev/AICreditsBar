/* Read-only kernel task accounting. Compile against the host macOS SDK.
 * XNU task.c maps task_gpu_utilisation to task_gpu_ns and task_energy to
 * usage.ru_energy_nj. Nanojoules are a kernel attribution, not battery drain.
 * https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c
 */
#include <mach/mach.h>
#include <mach/task_info.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    long pid = strtol(argv[1], &end, 10);
    if (!end || *end || pid <= 0 || pid > INT32_MAX) return 2;
    task_name_t task = MACH_PORT_NULL;
    kern_return_t result = task_name_for_pid(mach_task_self(), (int)pid, &task);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "task_name_for_pid: kernel error %d\n", result);
        return 1;
    }
    task_power_info_v2_data_t info = {0};
    mach_msg_type_number_t count = TASK_POWER_INFO_V2_COUNT;
    result = task_info(task, TASK_POWER_INFO_V2, (task_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), task);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "task_info: kernel error %d\n", result);
        return 1;
    }
    printf("{\"gpu_nanoseconds\":%" PRIu64 ",\"task_cpu_energy_nanojoules\":%" PRIu64 "}\n",
           info.gpu_energy.task_gpu_utilisation, info.task_energy);
    return 0;
}
