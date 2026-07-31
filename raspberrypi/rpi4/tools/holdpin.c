// SPDX-License-Identifier: Apache-2.0
/* holdpin <gpio> <0|1> : drive a line and hold it until killed. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/gpio.h>
int main(int argc,char**argv){
	struct gpio_v2_line_request r; struct gpio_v2_line_values v;
	int chip; if(argc<3){fprintf(stderr,"usage: holdpin <gpio> <0|1>\n");return 2;}
	chip=open("/dev/gpiochip0",O_RDONLY); if(chip<0){perror("gpiochip0");return 1;}
	memset(&r,0,sizeof r); r.offsets[0]=atoi(argv[1]); r.num_lines=1;
	r.config.flags=GPIO_V2_LINE_FLAG_OUTPUT; snprintf(r.consumer,sizeof r.consumer,"holdpin");
	if(ioctl(chip,GPIO_V2_GET_LINE_IOCTL,&r)<0){perror("get_line");return 1;}
	memset(&v,0,sizeof v); v.mask=1; v.bits=(atoi(argv[2])!=0);
	if(ioctl(r.fd,GPIO_V2_LINE_SET_VALUES_IOCTL,&v)<0){perror("set");return 1;}
	pause(); return 0;
}
