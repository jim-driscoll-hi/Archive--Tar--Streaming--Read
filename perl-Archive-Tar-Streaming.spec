Name: perl-Archive-Tar-Streaming
Version: 0.2.0
Release: 1
License: BSD
Summary: Common libraries with unrestricted internal distribution
Group: Development/Libraries
Packager: Jim Driscoll <jim.driscoll@heartinternet.co.uk>
Source: Archive-Tar-Streaming-%{version}.tar
BuildArch: noarch
BuildRoot: %{_builddir}/%{name}-%{version}-%{release}

%description
Perl libraries to support streaming to and from zip files.

%prep
%setup -n Archive-Tar-Streaming-%{version}

%build

%install
install -d $RPM_BUILD_ROOT/%{perl_vendorlib}/Archive/Tar/Streaming
install Archive/Tar/Streaming/*.pm $RPM_BUILD_ROOT/%{perl_vendorlib}/Archive/Tar/Streaming/

%files
%defattr(-,root,root)
%{perl_vendorlib}/Archive/Tar/Streaming

%changelog
* Fri Nov 21 2014 Jim Driscoll <jim.driscoll@heartinternet.co.uk> 0.2.0-1
- Bugfixes relating to GNU tar long name formats
* Tue Apr 29 2014 Jim Driscoll <jim.driscoll@heartinternet.co.uk> 0.1.0-1
- Initial RPM

