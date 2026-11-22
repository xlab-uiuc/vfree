// SPDX-License-Identifier: MIT
/*
 * zc_tput: one TCP flow for the zero-copy throughput experiments.
 *
 *   zc_tput recv_zc|recv <bind_ip> <port> <logfile>
 *   zc_tput send_zc|send <server_ip> <port> <logfile> [send_bytes]
 *
 * recv_zc  receives with getsockopt(TCP_ZEROCOPY_RECEIVE): payload pages are
 *          mapped into this process instead of copied. Bytes the kernel cannot
 *          map are read normally and counted as copied.
 * send_zc  sends with send(MSG_ZEROCOPY) and reuses a buffer only after its
 *          completion arrives on the socket error queue.
 * recv and send are the plain copying peers used on the bare-metal machine.
 *
 * Receivers accept one connection and exit at EOF. Senders run until killed.
 * Once a second, and on exit, a line is appended to <logfile>:
 *
 *   <CLOCK_REALTIME ns> <bytes> <a> <b>
 *
 *   recv_zc: a = bytes mapped, b = bytes copied
 *   send_zc: a = completed sends, b = completed sends the kernel copied
 *   recv, send: a = b = 0
 *
 * collect-zc-tput.py turns these cumulative counters into rates over the
 * measurement window recorded by the experiment runner.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/errqueue.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef TCP_ZEROCOPY_RECEIVE
#define TCP_ZEROCOPY_RECEIVE 35
#endif
#ifndef SO_ZEROCOPY
#define SO_ZEROCOPY 60
#endif
#ifndef MSG_ZEROCOPY
#define MSG_ZEROCOPY 0x4000000
#endif
#ifndef SO_EE_ORIGIN_ZEROCOPY
#define SO_EE_ORIGIN_ZEROCOPY 5
#endif
#ifndef SO_EE_CODE_ZEROCOPY_COPIED
#define SO_EE_CODE_ZEROCOPY_COPIED 1
#endif

/*
 * Leading fields of struct tcp_zerocopy_receive (Linux 4.18+). The kernel
 * accepts this shorter layout and leaves its newer options (copy buffer,
 * control messages) off. Defined here so the build does not depend on the
 * installed linux/tcp.h, which is older than the running kernel on the guest.
 */
struct zc_receive {
	uint64_t address;
	uint32_t length;
	uint32_t recv_skip_hint;
	uint32_t inq;
	int32_t err;
};

#ifndef ZC_CC
#define ZC_CC "dctcp" /* sender congestion control; override only for local tests */
#endif

#define RECV_CHUNK (512u * 1024)  /* bytes mapped or read per call */
#define SEND_SLOTS 16u            /* outstanding MSG_ZEROCOPY buffers */
#define LOG_PERIOD_NS 1000000000ull

static volatile sig_atomic_t stop;
static int log_fd = -1;
static uint64_t next_log_ns;
static uint64_t total, count_a, count_b;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static uint64_t now_ns(clockid_t clock)
{
	struct timespec ts;

	if (clock_gettime(clock, &ts))
		err(1, "clock_gettime");
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void write_log(void)
{
	if (dprintf(log_fd, "%" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 "\n",
		    now_ns(CLOCK_REALTIME), total, count_a, count_b) < 0)
		err(1, "write log");
}

static void maybe_log(void)
{
	uint64_t t = now_ns(CLOCK_MONOTONIC);

	if (t >= next_log_ns) {
		write_log();
		next_log_ns = t + LOG_PERIOD_NS;
	}
}

static unsigned long number(const char *arg, unsigned long max)
{
	char *end;
	unsigned long v;

	errno = 0;
	v = strtoul(arg, &end, 10);
	if (errno || end == arg || *end || v == 0 || v > max)
		errx(2, "invalid number: %s", arg);
	return v;
}

static void receive(int fd, bool zc)
{
	char *buf = malloc(RECV_CHUNK);
	void *region = NULL;

	if (!buf)
		err(1, "malloc");
	if (zc) {
		region = mmap(NULL, RECV_CHUNK, PROT_READ, MAP_SHARED, fd, 0);
		if (region == MAP_FAILED)
			err(1, "mmap on TCP socket");
		if (fcntl(fd, F_SETFL, O_NONBLOCK))
			err(1, "O_NONBLOCK");
	}

	while (!stop) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		ssize_t n;

		if (poll(&p, 1, 1000) < 0) {
			if (errno == EINTR)
				continue;
			err(1, "poll");
		}
		maybe_log();
		if (!(p.revents & (POLLIN | POLLHUP | POLLERR)))
			continue;

		if (!zc) {
			n = read(fd, buf, RECV_CHUNK);
			if (n == 0)
				break;
			if (n < 0) {
				if (errno == EINTR)
					continue;
				err(1, "read");
			}
			total += (uint64_t)n;
			continue;
		}

		struct zc_receive z = {
			.address = (uintptr_t)region,
			.length = RECV_CHUNK,
		};
		socklen_t len = sizeof(z);

		if (getsockopt(fd, IPPROTO_TCP, TCP_ZEROCOPY_RECEIVE, &z, &len)) {
			/* The call fails (EIO) once the peer has closed: treat as EOF. */
			int saved = errno;

			if (recv(fd, buf, 1, MSG_PEEK | MSG_DONTWAIT) == 0)
				break;
			errno = saved;
			err(1, "TCP_ZEROCOPY_RECEIVE");
		}
		if (z.err)
			errx(1, "socket error %d", z.err);
		if (z.length) {
			total += z.length;
			count_a += z.length;
			/* Release the pages now rather than in the next call. */
			if (madvise(region, z.length, MADV_DONTNEED))
				err(1, "madvise");
		}
		/*
		 * Nothing mapped and nothing to copy: peek to tell EOF apart
		 * from a wakeup that raced with new data. A plain read here
		 * would copy data the next call could have mapped.
		 */
		if (!z.length && !z.recv_skip_hint) {
			n = recv(fd, buf, 1, MSG_PEEK | MSG_DONTWAIT);
			if (n == 0)
				break;
			if (n < 0 && errno != EAGAIN && errno != EINTR)
				err(1, "recv(MSG_PEEK)");
			continue;
		}
		/* Bytes the kernel could not map (not whole, page-aligned payload). */
		if (z.recv_skip_hint) {
			size_t want = z.recv_skip_hint;

			if (want > RECV_CHUNK)
				want = RECV_CHUNK;
			n = read(fd, buf, want);
			if (n == 0)
				break;
			if (n < 0) {
				if (errno == EAGAIN || errno == EINTR)
					continue;
				err(1, "read");
			}
			total += (uint64_t)n;
			count_b += (uint64_t)n;
		}
	}
	if (region)
		munmap(region, RECV_CHUNK);
	free(buf);
}

/* Read MSG_ZEROCOPY completions; returns how many sends they cover. */
static uint64_t drain_completions(int fd)
{
	uint64_t done = 0;

	for (;;) {
		char control[CMSG_SPACE(sizeof(struct sock_extended_err)) + 64];
		struct msghdr msg = {
			.msg_control = control,
			.msg_controllen = sizeof(control),
		};
		struct cmsghdr *cm;

		if (recvmsg(fd, &msg, MSG_ERRQUEUE | MSG_DONTWAIT) < 0) {
			if (errno == EAGAIN || errno == EINTR)
				return done;
			err(1, "recvmsg(MSG_ERRQUEUE)");
		}
		for (cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm)) {
			struct sock_extended_err *ee;
			uint64_t n;

			if (!((cm->cmsg_level == SOL_IP && cm->cmsg_type == IP_RECVERR) ||
			      (cm->cmsg_level == SOL_IPV6 && cm->cmsg_type == IPV6_RECVERR)))
				continue;
			ee = (struct sock_extended_err *)CMSG_DATA(cm);
			if (ee->ee_errno || ee->ee_origin != SO_EE_ORIGIN_ZEROCOPY)
				errx(1, "unexpected error queue entry: errno %u origin %u",
				     ee->ee_errno, ee->ee_origin);
			/* One entry covers send ids ee_info..ee_data. */
			n = (uint64_t)(uint32_t)(ee->ee_data - ee->ee_info) + 1;
			done += n;
			count_a += n;
			if (ee->ee_code & SO_EE_CODE_ZEROCOPY_COPIED)
				count_b += n;
		}
	}
}

static void transmit(int fd, bool zc, size_t size)
{
	unsigned slots = zc ? SEND_SLOTS : 1;
	uint64_t issued = 0, completed = 0;
	char *pool;

	if (posix_memalign((void **)&pool, 4096, (size_t)slots * size))
		errx(1, "buffer allocation failed");
	memset(pool, 0x5a, (size_t)slots * size);
	if (zc) {
		int one = 1;

		if (setsockopt(fd, SOL_SOCKET, SO_ZEROCOPY, &one, sizeof(one)))
			err(1, "SO_ZEROCOPY");
	}

	while (!stop) {
		ssize_t n;

		maybe_log();
		if (zc) {
			completed += drain_completions(fd);
			/* Wait while every buffer is still owned by the kernel. */
			while (!stop && issued - completed >= slots) {
				struct pollfd p = { .fd = fd, .events = 0 };

				if (poll(&p, 1, 1000) < 0 && errno != EINTR)
					err(1, "poll for completions");
				completed += drain_completions(fd);
				maybe_log();
			}
			if (stop)
				break;
		}
		n = send(fd, pool + (size_t)(issued % slots) * size, size,
			 zc ? MSG_ZEROCOPY : 0);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			/* Out of option memory for notifications: let some complete. */
			if (zc && errno == ENOBUFS) {
				struct pollfd p = { .fd = fd, .events = 0 };

				poll(&p, 1, 10);
				continue;
			}
			err(1, "send");
		}
		total += (uint64_t)n;
		if (zc)
			issued++;
	}
	free(pool);
}

int main(int argc, char **argv)
{
	struct sockaddr_in addr = { .sin_family = AF_INET };
	struct sigaction sa = { .sa_handler = on_signal };
	bool zc, sender;
	size_t size = 65536;
	int fd;

	if (argc != 5 && argc != 6)
		errx(2, "usage: zc_tput recv_zc|recv|send_zc|send ip port logfile [send_bytes]");
	if (!strcmp(argv[1], "recv_zc") || !strcmp(argv[1], "recv"))
		sender = false;
	else if (!strcmp(argv[1], "send_zc") || !strcmp(argv[1], "send"))
		sender = true;
	else
		errx(2, "unknown mode: %s", argv[1]);
	zc = strstr(argv[1], "_zc") != NULL;
	addr.sin_port = htons((uint16_t)number(argv[3], 65535));
	if (inet_pton(AF_INET, argv[2], &addr.sin_addr) != 1)
		errx(2, "invalid IPv4 address: %s", argv[2]);
	if (argc == 6)
		size = number(argv[5], 1u << 20);

	/* No SA_RESTART: blocking calls return EINTR so the loops can exit. */
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	log_fd = open(argv[4], O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (log_fd < 0)
		err(1, "open %s", argv[4]);
	dprintf(log_fd, "# %s port %s send_bytes %zu\n", argv[1], argv[3], size);

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		err(1, "socket");

	if (sender) {
		/* Same congestion control as the iperf3 clients (-C dctcp). */
		if (setsockopt(fd, IPPROTO_TCP, TCP_CONGESTION, ZC_CC, strlen(ZC_CC)))
			err(1, "TCP_CONGESTION %s", ZC_CC);
		while (connect(fd, (struct sockaddr *)&addr, sizeof(addr))) {
			if (stop || (errno != ECONNREFUSED && errno != EINTR))
				err(1, "connect %s:%s", argv[2], argv[3]);
			sleep(1); /* receiver not listening yet */
		}
		write_log();
		transmit(fd, zc, size);
	} else {
		int one = 1, conn;

		if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) ||
		    bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || listen(fd, 1))
			err(1, "listen on %s:%s", argv[2], argv[3]);
		conn = accept(fd, NULL, NULL);
		if (conn < 0) {
			if (errno == EINTR)
				return 0;
			err(1, "accept");
		}
		close(fd);
		fd = conn;
		write_log();
		receive(fd, zc);
	}
	write_log();
	close(fd);
	close(log_fd);
	return 0;
}
