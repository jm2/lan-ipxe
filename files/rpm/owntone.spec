# owntone.spec.  Generated from owntone.spec.in by configure.
# -*- Mode:rpm-spec -*-
# Upstream's release spec, adapted to Fedora 42+ native sysusers.d handling
# and the release-download Source0 URL.
# setup-fedora-workstation.sh builds the latest release by defining
# owntone_version; the default below keeps the spec usable by hand.
%{!?owntone_version:%global owntone_version 29.3}
%global username owntone
%global groupname owntone

%bcond_without alsa
%bcond_without pulseaudio
%bcond_with chromecast

%global _hardened_build 1

Summary: iTunes-compatible DAAP server with MPD and RSP support
Name: owntone
Version: %{owntone_version}
Release: 1%{?dist}
License: GPLv2+
Group: Applications/Multimedia
Url: https://github.com/owntone/owntone-server
Source0: %{url}/releases/download/%{version}/%{name}-%{version}.tar.xz
%{?systemd_ordering}
BuildRequires: gcc, make, bison, flex, pkgconfig, libunistring-devel
BuildRequires: systemd-rpm-macros
BuildRequires: pkgconfig(zlib), pkgconfig(libconfuse), pkgconfig(libxml-2.0)
BuildRequires: pkgconfig(sqlite3) >= 3.5.0, pkgconfig(libevent) >= 2.0.0
BuildRequires: pkgconfig(json-c), libgcrypt-devel >= 1.2.0
BuildRequires: libgpg-error-devel >= 1.6
BuildRequires: pkgconfig(libavformat), pkgconfig(libavcodec)
BuildRequires: pkgconfig(libswscale), pkgconfig(libavutil)
BuildRequires: pkgconfig(libavfilter), pkgconfig(libcurl)
BuildRequires: pkgconfig(openssl), pkgconfig(libwebsockets) > 2.0.2
BuildRequires: pkgconfig(libsodium), pkgconfig(avahi-client) >= 0.6.24
BuildRequires: pkgconfig(libprotobuf-c)
# pkgconfig(libplist) not used universally, so require libplist-devel instead
BuildRequires: libplist-devel >= 0.16
# Fedora 42+ creates the service account from the sysusers.d file written in
# %%install (the release tarball ships none). EL and older Fedora releases
# need the legacy %%pre scriptlet instead.
%if 0%{?fedora} < 42
Requires(pre): shadow-utils
%endif
%if %{with alsa}
BuildRequires: pkgconfig(alsa)
%endif
%if %{with pulseaudio}
BuildRequires: pkgconfig(libpulse)
%endif
%if %{with chromecast}
BuildRequires: pkgconfig(gnutls)
%endif
Requires: avahi

%global homedir %{_localstatedir}/lib/%{name}
%{!?_pkgdocdir: %global _pkgdocdir %{_docdir}/%{name}-%{version}}

%description
OwnTone is a DAAP/DACP (iTunes), MPD (Music Player Daemon) and RSP (Roku) media
server.

It has support for AirPlay devices/speakers, Apple Remote (and compatibles),
MPD clients, Chromecast, network streaming, internet radio, Spotify and LastFM.

It does not support streaming video by AirPlay nor Chromecast.

DAAP stands for Digital Audio Access Protocol, and is the protocol used
by iTunes and friends to share/stream media libraries over the network.

%prep
%setup -q

%build
%configure \
  --with%{!?with_alsa:out}-alsa --with%{!?with_pulseaudio:out}-pulseaudio \
  --with-libwebsockets --with-avahi %{?with_chromecast:--enable-chromecast} \
  --with-user=%{username} --with-group=%{groupname} \
  --with-systemddir=%{_unitdir}
%make_build

%install
make install DESTDIR=%{buildroot} docdir=%{_pkgdocdir}
rm -f %{buildroot}%{_pkgdocdir}/INSTALL
mkdir -p %{buildroot}%{homedir}
mkdir -p %{buildroot}%{_localstatedir}/log
touch %{buildroot}%{_localstatedir}/log/%{name}.log
rm -f %{buildroot}%{_libdir}/%{name}/*.la
install -d %{buildroot}%{_sysusersdir}
cat >%{buildroot}%{_sysusersdir}/%{name}.conf <<'EOF'
# Type Name ID GECOS Home directory Shell
g %{groupname} -
u %{username} -:%{groupname} "%{name} User" %{homedir} /sbin/nologin
EOF

%if 0%{?fedora} < 42
%pre
getent group %{groupname} >/dev/null || groupadd -r %{groupname}
getent passwd %{username} >/dev/null || \
    useradd -r -g %{groupname} -d %{homedir} -s /sbin/nologin \
    -c '%{name} User' %{username}
exit 0
%endif

%post
%systemd_post %{name}.service

%preun
%systemd_preun %{name}.service

%postun
%systemd_postun_with_restart %{name}.service

%files
%{!?_licensedir:%global license %%doc}
%license COPYING
%{_pkgdocdir}
%config(noreplace) %{_sysconfdir}/owntone.conf
%{_sbindir}/owntone
%{_libdir}/%{name}/
%{_datarootdir}/%{name}/
%{_unitdir}/%{name}.service
%{_unitdir}/%{name}@.service
%{_sysusersdir}/%{name}.conf
%attr(0750,%{username},%{groupname}) %{_localstatedir}/cache/%{name}
%attr(0750,%{username},%{groupname}) %{homedir}
%ghost %{_localstatedir}/log/%{name}.log
%{_mandir}/man?/*

%changelog
* Mon Jan 17 2022 Espen Jürgensen <espen.jurgensen@gmail.com> - 28.3-1
   - Remove antlr dependency
   - Add bison/flex dependency

* Mon Nov 22 2021 Derek Atkins <derek@ihtfp.com> - 28.2-1
   - Release tarball is a XZ not GZ file
   - Configure always needs protobuf-c, not just for chromecast
   - Exclude build-system-installed service file and use system location

* Sat Mar 17 2018 Scott Shambarger <devel@shambarger.net> - 26.0-1
   - 26.0 release.
   - Update spec file to handle new feature defaults.
   - Added new files/directories.

* Tue Dec 20 2016 Scott Shambarger <devel@shambarger.net> - 24.2-1
   - Initial RPM release candidate.
