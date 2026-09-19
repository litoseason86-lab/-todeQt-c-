#include "MacLocalPeerIdentity.h"
#include <sys/socket.h>
#include <unistd.h>

bool MacLocalPeerIdentity::isCurrentUser(qintptr descriptor)
{
    uid_t user = 0;
    gid_t group = 0;
    return ::getpeereid(int(descriptor), &user, &group) == 0 && user == ::geteuid();
}
