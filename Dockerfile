ARG	BASEIMG=amitie10g/baseimage
ARG	BASEIMG_VERS=focal
ARG	PHP_VERS="7.4"
ARG	ZM_VERS="1.34"
FROM	$BASEIMG:$BASEIMG_VERS AS base

LABEL	maintainer="dlandon"

# Global arguments and environment variables
ARG	BASEIMG_VERS
ARG	PHP_VERS
ARG	ZM_VERS
ENV	DEBCONF_NONINTERACTIVE_SEEN="true" \
	DEBIAN_FRONTEND="noninteractive" \
	PYTHONPYCACHEPREFIX="/tmp/pip" \
	PATH="/opt/venv/bin:$PATH" \
	DISABLE_SSH="true" \
	HOME="/root" \
	LC_ALL="C.UTF-8" \
	LANG="en_US.UTF-8" \
	LANGUAGE="en_US.UTF-8" \
	TZ="Etc/UTC" \
	TERM="xterm" \
	PHP_VERS=$PHP_VERS \
	ZM_VERS=$ZM_VERS \
	PUID="99" \
	PGID="100"

# Base packages
RUN	case $BASEIMG_VERS in bionic|bionic-i386|focal|groovy|hirsute) \
		add-apt-repository -y ppa:iconnor/zoneminder-$ZM_VERS && \
		add-apt-repository ppa:ondrej/php && \
		add-apt-repository ppa:ondrej/apache2 ;; \
	esac && \
	apt-get update && \
	apt-get -y install apache2 mariadb-server && \
	apt-get -y install ssmtp mailutils net-tools wget sudo && \
	apt-get -y install php$PHP_VERS-fpm libapache2-mod-php$PHP_VERS php$PHP_VERS-mysql php$PHP_VERS-gd && \
	apt-get -y install libcrypt-mysql-perl libyaml-perl libjson-perl && \
	sh -lc 'if ! apt-get -y install libopenblas0; then apt-get -y install libopenblas-dev; fi' && \
	apt-get -y install --no-install-recommends \
		libvlc-dev \
		libvlccore-dev \
		vlc-bin \
		vlc-plugin-base \
		vlc-plugin-video-output \
		libavutil-dev \
		ffmpeg \
		python3-pip \
		python3-setuptools \
		python3-shapely \
		python3-wheel \
		python3-future && \
	apt-get -y install zoneminder && \
	python3 -m pip install --upgrade pip

# Builder container for dlib
FROM base AS builder

# Bring dependencies
RUN apt-get -y install \
		build-essential \
		cmake \
		python3-dev \
		python3-venv \
		libopenblas-dev \
		liblapack-dev \
		libblas-dev

# Build dlib
FROM builder AS python-builder
RUN python3 -m pip download dlib
RUN python3 -m pip wheel --default-timeout 1800 dlib

# Build Perl modules
FROM builder AS perl-builder
RUN export PERL_MM_USE_DEFAULT=1 && \
	perl -MCPAN -e "fforce install inc::latest" && \
	perl -MCPAN -e "fforce install PAR::Dist" && \
	perl -MCPAN -e "fforce install Protocol::WebSocket" && \
	perl -MCPAN -e "fforce test Net::WebSocket::Server" && \
	perl -MCPAN -e "fforce test LWP::Protocol::https" && \
	perl -MCPAN -e "fforce test Config::IniFiles" && \
	perl -MCPAN -e "fforce test Net::MQTT::Simple" && \
	perl -MCPAN -e "fforce test Net::MQTT::Simple::Auth" && \
	perl -MCPAN -e "fforce test Time::Piece"

# New container
FROM base

COPY init/ /etc/my_init.d/
COPY defaults/ /tmp/
COPY zmeventnotification/ /root/zmeventnotification/
COPY --from=amitie10g/zoneminder:models / /root/models
COPY --from=python-builder /root/.cache/pip/wheels/ /root/.cache/pip/wheels/
COPY --from=perl-builder /root/.cpan/ /root/.cpan/

RUN	python3 -m pip install /root/zmeventnotification && \
	python3 -m pip install dlib && \
	python3 -m pip install face_recognition && \
	python3 -m pip install opencv-contrib-python-headless && \
	rm /etc/mysql/my.cnf && \
	cp /etc/mysql/mariadb.conf.d/50-server.cnf /etc/mysql/my.cnf && \
	adduser www-data video && \
	a2enmod php$PHP_VERS proxy_fcgi ssl rewrite expires headers && \
	a2enconf php$PHP_VERS-fpm zoneminder && \
	echo "extension=apcu.so" > /etc/php/$PHP_VERS/mods-available/apcu.ini && \
	echo "extension=mcrypt.so" > /etc/php/$PHP_VERS/mods-available/mcrypt.ini && \
	perl -MCPAN -e "CPAN::Shell->notest('install', 'Net::WebSocket::Server')" && \
	perl -MCPAN -e "CPAN::Shell->notest('install', 'LWP::Protocol::https')" && \
	perl -MCPAN -e "CPAN::Shell->notest('install', 'Config::IniFiles')" && \
	perl -MCPAN -e "CPAN::Shell->notest('install', 'Net::MQTT::Simple')" && \
	perl -MCPAN -e "CPAN::Shell->notest('install', 'Net::MQTT::Simple::Auth')" && \
	perl -MCPAN -e "CPAN::Shell->notest('install', 'Time::Piece')" && \
	chown -R www-data:www-data /usr/share/zoneminder/ && \
	echo "ServerName localhost" >> /etc/apache2/apache2.conf && \
	sed -i "s|^;date.timezone =.*|date.timezone = ${TZ}|" /etc/php/$PHP_VERS/apache2/php.ini && \
	service mysql start && \
	mysql -uroot < /usr/share/zoneminder/db/zm_create.sql && \
	mysql -uroot -e "grant all on zm.* to 'zmuser'@localhost identified by 'zmpass';" && \
	mysqladmin -uroot reload && \
	mysql -sfu root < "/tmp/mysql_secure_installation.sql" && \
	mysql -sfu root < "/tmp/mysql_defaults.sql" && \
	mv /tmp/zoneminder /etc/init.d/zoneminder && \
	chmod +x /etc/init.d/zoneminder && \
	service mysql restart && \
	sleep 5 && \
	service apache2 start && \
	service zoneminder start && \
	systemd-tmpfiles --create zoneminder.conf && \
	mv /tmp/default-ssl.conf /etc/apache2/sites-enabled/default-ssl.conf && \
	mkdir /etc/apache2/ssl/ && \
	mkdir -p /var/lib/zmeventnotification/images && \
	chown -R www-data:www-data /var/lib/zmeventnotification/ && \
	chmod -R +x /etc/my_init.d/ && \
	cp -p /etc/zm/zm.conf /root/zm.conf && \
	echo "#!/bin/sh\n\n/usr/bin/zmaudit.pl -f" >> /etc/cron.weekly/zmaudit && \
	chmod +x /etc/cron.weekly/zmaudit && \
	cp /etc/apache2/ports.conf /etc/apache2/ports.conf.default && \
	cp /etc/apache2/sites-enabled/default-ssl.conf /etc/apache2/sites-enabled/default-ssl.conf.default && \
	sed -i s#3.13#3.25#g /etc/syslog-ng/syslog-ng.conf && \
	sed -i 's#use_dns(no)#use_dns(yes)#' /etc/syslog-ng/syslog-ng.conf && \
	apt-get -y clean && \
	apt-get -y autoremove && \
	rm -rf /tmp/* /var/tmp/* /root/.cache/* /root/.cpan && \
	chmod +x /etc/my_init.d/*.sh

VOLUME \
	["/config"] \
	["/var/cache/zoneminder"]

EXPOSE 80 443 9000

WORKDIR /root
CMD ["/sbin/my_init"]