ARG BUILD_FROM
FROM $BUILD_FROM

RUN apt update \
  && apt install -y sudo wget procps curl systemd network-manager \
  && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --set iptables /usr/sbin/iptables-legacy

RUN curl -sL https://install.raspap.com | bash -s -- --yes --openvpn 0 --adblock 0 --repo letranloc/raspap-webgui --branch master

COPY rootfs/ /

RUN chmod a+x /*.sh

EXPOSE 80

CMD [ "/run.sh" ]
