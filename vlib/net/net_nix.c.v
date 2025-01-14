module net

#include <unistd.h>
#include <sys/select.h>
// inet.h is needed for inet_ntop on macos
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <fcntl.h>

#flag solaris -lsocket

pub fn error_code() int {
	return C.errno
}

fn init() {
}

pub const (
	msg_nosignal      = 0x4000

	error_ewouldblock = C.EWOULDBLOCK
)
