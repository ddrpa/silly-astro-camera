# Silly Astro Camera

iPhone 后置相机取景时，按当前时间、位置和手机姿态，把计算出来的月面叠到月亮应该出现的地方。拍下的照片会按同一套几何关系把月面画进成片。

手机罗盘和镜头模型的误差通常大于历表本身。界面上可以把月面拖到真实月亮上，记下方位角和高度角的固定偏差，之后的预览和成片都沿用这个偏差。

## 功能

- 取景预览上叠加当前月相、天平动朝向和视直径。
- 月亮不在画面里时，边框上给出指向和角距离。
- 可开关地平线以下的月面，以及是否按真实月相打光（关掉则画满月圆盘，朝向仍随天平动变化）。
- 变焦、曝光补偿、点按对焦测光。
- 校正：把月面拖到眼里的月亮上，偏差写入本机。
- 拍照后把月面合成进照片，保存到相册并带上拍摄位置。

角度在进入三角函数之前都换成弧度。写回角度时用 $\mathrm{deg}(\theta)=\theta\cdot 180/\pi$。三个折返函数和代码一致：$\mathrm{wrap}_{360}$ 折进 $[0,360)$，$\mathrm{wrap}_{\pm 180}$ 折进 $(-180,180]$，$\mathrm{wrap}_{\pi}$ 折进 $(-\pi,\pi]$。

## 坐标系

方位角 $A$ 从正北起、向东增加；高度角 $h$ 从地平线起、向天顶增加，向下为负。世界坐标取 $+X$ 向北、$+Y$ 向西、$+Z$ 向天顶，与 Core Motion 的 `xTrueNorthZVertical` 一致。单位方向是

$$
\mathbf{d}(A,h)=(\cos h\cos A,\ -\cos h\sin A,\ \sin h)
$$

反解先归一化，再

$$
h=\arcsin(d_z),\qquad A=\operatorname{atan2}(-d_y,d_x)
$$

设备坐标是 $+X$ 向右、$+Y$ 指向手机顶部、$+Z$ 指出屏幕。后置相机的光轴在设备坐标里是 $(0,0,-1)$。Core Motion 旋转矩阵的元素记为 $m_{ij}$。代码把设备向量 $\mathbf{d}$ 乘以该矩阵的转置，得到世界坐标：

$$
\begin{aligned}
v_x&=m_{11}d_x+m_{21}d_y+m_{31}d_z\\
v_y&=m_{12}d_x+m_{22}d_y+m_{32}d_z\\
v_z&=m_{13}d_x+m_{23}d_y+m_{33}d_z
\end{aligned}
$$

画面的右 $\mathbf{r}_d$ 和上 $\mathbf{u}_d$ 先在设备坐标里按界面方向选取，再做同一次变换：

| 界面 | $\mathbf{r}_d$ | $\mathbf{u}_d$ |
| --- | --- | --- |
| 竖屏 | $(1,0,0)$ | $(0,1,0)$ |
| 倒置 | $(-1,0,0)$ | $(0,-1,0)$ |
| 左横 | $(0,-1,0)$ | $(1,0,0)$ |
| 右横 | $(0,1,0)$ | $(-1,0,0)$ |

得到的光轴 $\mathbf{f}$、画面右 $\mathbf{r}$、画面上 $\mathbf{u}$ 就是后面投影用的相机姿态。姿态约 60 Hz 更新，优先真北；没有真北参考系时改用磁北。

## 时间与基本引数

观测时刻用 UTC 拆成年 $Y$、月 $M$ 和日的小数 $D$。$D$ 含时分秒：

$$
D=\mathrm{day}+\frac{1}{24}\left(\mathrm{hour}+\frac{1}{60}\left(\mathrm{minute}+\frac{\mathrm{second}+\mathrm{ns}/10^{9}}{60}\right)\right)
$$

$M\le 2$ 时令 $Y\leftarrow Y-1$、$M\leftarrow M+12$。格里高利改正用整数除法 $a=\lfloor Y/100\rfloor$，

$$
B=2-a+\lfloor a/4\rfloor
$$

儒略日是

$$
\mathrm{JD}=\lfloor 365.25(Y+4716)\rfloor+\lfloor 30.6001(M+1)\rfloor+D+B-1524.5
$$

自 J2000.0 起的儒略世纪是

$$
T=(\mathrm{JD}-2451545.0)/36525
$$

月亮级数用的五个基本引数（度，再折进 $[0,360)$；除升交点外，进入三角函数前换成弧度）是

$$
\begin{aligned}
L'&=218.3164477+481267.88123421\,T-0.0015786\,T^{2}+T^{3}/538841-T^{4}/65194000\\
D&=297.8501921+445267.1114034\,T-0.0018819\,T^{2}+T^{3}/545868-T^{4}/113065000\\
M&=357.5291092+35999.0502909\,T-0.0001536\,T^{2}+T^{3}/24490000\\
M'&=134.9633964+477198.8675055\,T+0.0087414\,T^{2}+T^{3}/69699-T^{4}/14712000\\
F&=93.2720950+483202.0175233\,T-0.0036539\,T^{2}-T^{3}/3526000+T^{4}/863310000
\end{aligned}
$$

$L'$ 是月亮平黄经，$D$ 是月日距角，$M$ 是太阳平近点角，$M'$ 是月亮平近点角，$F$ 是纬度引数。升交点平黄经保留为度：

$$
\Omega=125.04452-1934.136261\,T+0.0020708\,T^{2}+T^{3}/450000
$$

这组多项式来自 Meeus《Astronomical Algorithms》第 47 章。历算约每秒重算一次。这里得到的是几何地平高度；大气折射在几何高度算完之后再加，见下文。

## 太阳

太阳另有一套平黄经和平近点角（度）：

$$
\begin{aligned}
L_{0}&=280.46646+36000.76983\,T+0.0003032\,T^{2}\\
M_{\odot}&=357.52911+35999.05029\,T-0.0001537\,T^{2}\\
e&=0.016708634-0.000042037\,T-0.0000001267\,T^{2}
\end{aligned}
$$

中心差（度）是

$$
C=(1.914602-0.004817\,T-0.000014\,T^{2})\sin M_{\odot}+(0.019993-0.000101\,T)\sin 2M_{\odot}+0.000289\sin 3M_{\odot}
$$

真黄经是 $L_{0}+C$。再用一个只含 $T$ 一次项的升交点 $\Omega_{\odot}=125.04-1934.136\,T$ 做光行差和章动的小修正，得到视黄经（度）

$$
\lambda_{\odot}=L_{0}+C-0.00569-0.00478\sin\Omega_{\odot}
$$

日地距离（天文单位）是

$$
R=\frac{1.000001018\,(1-e^{2})}{1+e\cos(M_{\odot}+C)}
$$

太阳黄纬取 0。

## 月亮的黄道坐标

黄经、黄纬是 $D,M,M',F$ 的正弦级数，地心距离是对应的余弦级数。太阳偏心率因子

$$
E=1-0.002516\,T-0.0000074\,T^{2}
$$

按该项里 $M$ 的倍数 $|M_{i}|$ 取值：$|M_{i}|=1$ 时乘 $E$，$|M_{i}|=2$ 时乘 $E^{2}$，否则乘 1。黄经与距离共用同一组角，系数 $l_{i}$ 的单位是 $10^{-6}$ 度，$r_{i}$ 的单位是 $10^{-3}\,\mathrm{km}$：

$$
\begin{aligned}
\sum L&=\sum_{i} E^{|M_{i}|}\,l_{i}\sin(D_{i}D+M_{i}M+M'_{i}M'+F_{i}F)\\
\sum r&=\sum_{i} E^{|M_{i}|}\,r_{i}\cos(D_{i}D+M_{i}M+M'_{i}M'+F_{i}F)\\
\sum B&=\sum_{i} E^{|M_{i}|}\,b_{i}\sin(D_{i}D+M_{i}M+M'_{i}M'+F_{i}F)
\end{aligned}
$$

周期项表在 `longitudeTerms` 和 `latitudeTerms`。表外还有三项附加角（度）

$$
\begin{aligned}
A_{1}&=119.75+131.849\,T\\
A_{2}&=53.09+479264.290\,T\\
A_{3}&=313.45+481266.484\,T
\end{aligned}
$$

黄经和（仍是 $10^{-6}$ 度）再加

$$
3958\sin A_{1}+1962\sin(L'-F)+318\sin A_{2}
$$

黄纬和再加

$$
-2235\sin L'+382\sin A_{3}+175\sin(A_{1}-F)+175\sin(A_{1}+F)+127\sin(L'-M')-115\sin(L'+M')
$$

黄经章动取 $-17.20''\sin\Omega$，黄赤交角的章动取 $+9.20''\cos\Omega$。最终地心坐标是

$$
\begin{aligned}
\lambda&=L'+\sum L/10^{6}-17.20\sin\Omega\,/\,3600\\
\beta&=\sum B/10^{6}\\
\Delta&=385000.56+\sum r/1000
\end{aligned}
$$

$\lambda$、$\beta$ 以度计后再换成弧度，$\Delta$ 以千米计。视半径只用这份地心距离，

$$
\rho=\arcsin(1737.4/\Delta)
$$

$1737.4\,\mathrm{km}$ 是采用的月球半径。站心修正只改方向，不改 $\Delta$，因此也不改 $\rho$。

## 赤道坐标与恒星时

平黄赤交角（度）加上面的交角章动：

$$
\varepsilon_{0}=23.439291111-0.013004166\,T-0.00000016388\,T^{2}+0.0000005036\,T^{3}
$$

$$
\varepsilon=\varepsilon_{0}+9.20\cos\Omega\,/\,3600
$$

黄道 $(\lambda,\beta)$ 转到赤道 $(\alpha,\delta)$：

$$
\begin{aligned}
\alpha&=\operatorname{atan2}(\sin\lambda\cos\varepsilon-\tan\beta\sin\varepsilon,\ \cos\lambda)\\
\delta&=\arcsin(\sin\beta\cos\varepsilon+\cos\beta\sin\varepsilon\sin\lambda)
\end{aligned}
$$

$\alpha$ 再 $\mathrm{wrap}_{\pi}$。太阳走同一公式且 $\beta=0$。向量形式用于后面的月面坐标，绕 $X$ 轴转过 $\varepsilon$：

$$
(x,\ y\cos\varepsilon-z\sin\varepsilon,\ y\sin\varepsilon+z\cos\varepsilon)
$$

格林尼治平恒星时（度）是

$$
\theta=280.46061837+360.98564736629\,(\mathrm{JD}-2451545.0)+0.000387933\,T^{2}-T^{3}/38710000
$$

## 站心视差与地平坐标

月亮的地平视差最大约 $1^{\circ}$，和月面视直径同一量级，所以投影用站心方向。地理纬度 $\varphi$、东经 $\lambda_{\oplus}$ 来自定位，海拔 $H$ 以米计。地球赤道半径取 $a=6378.14\,\mathrm{km}$，扁率因子 $b/a=0.99664719$。归化纬度和观测者的地心坐标是

$$
\varphi'=\arctan(0.99664719\tan\varphi)
$$

$$
\begin{aligned}
u&=H/(1000\,a)\\
\rho\sin\varphi'&=0.99664719\sin\varphi'+u\sin\varphi\\
\rho\cos\varphi'&=\cos\varphi'+u\cos\varphi
\end{aligned}
$$

赤道地平视差角

$$
\pi_{\mathrm{m}}=\arcsin(a/\Delta)
$$

地心时角

$$
H=\mathrm{wrap}_{\pi}(\theta+\lambda_{\oplus}-\alpha)
$$

赤经改正

$$
\Delta\alpha=\operatorname{atan2}(-\rho\cos\varphi'\sin\pi_{\mathrm{m}}\sin H,\ \cos\delta-\rho\cos\varphi'\sin\pi_{\mathrm{m}}\cos H)
$$

记分母为 $G=\cos\delta-\rho\cos\varphi'\sin\pi_{\mathrm{m}}\cos H$，站心赤纬和改正后的时角是

$$
\begin{aligned}
\alpha'&=\mathrm{wrap}_{\pi}(\alpha+\Delta\alpha)\\
\delta'&=\operatorname{atan2}\bigl((\sin\delta-\rho\sin\varphi'\sin\pi_{\mathrm{m}})\cos\Delta\alpha,\ G\bigr)\\
H'&=\mathrm{wrap}_{\pi}(\theta+\lambda_{\oplus}-\alpha')
\end{aligned}
$$

地平坐标由站心时角和站心赤纬得到。$\sin h$ 先夹到 $[-1,1]$：

$$
\sin h=\sin\varphi\sin\delta'+\cos\varphi\cos\delta'\cos H'
$$

$$
h=\arcsin(\sin h)
$$

方位角公式以正南为零，加上 $\pi$ 后变成从正北量起：

$$
A_{\mathrm{S}}=\operatorname{atan2}(\sin H',\ \cos H'\sin\varphi-\tan\delta'\cos\varphi)
$$

$$
A=\mathrm{wrap}_{\pi}(A_{\mathrm{S}}+\pi)
$$

相位和月面朝向用下面两节的地心太阳、地心黄道月亮；地平方向用站心赤经赤纬。

## 大气

几何高度 $h$ 是上一节的站心高度，单位在公式里用度。气压取观测海拔上的标准大气：

$$
P=1013.25\exp(-H/8500)\,\mathrm{hPa}
$$

气温固定 $T=10^\circ\mathrm{C}$。真高度低于 $-1^\circ$ 时，折射公式的输入夹到 $-1^\circ$；高于 $89.5^\circ$ 时夹到 $89.5^\circ$。Saemundsson 公式在 $90^\circ$ 附近没有定义，而那里的折射已经小于 $1''$。

$$
R=\frac{1.02}{\tan\bigl(h+10.3/(h+5.11)\bigr)}\cdot\frac{P}{1010}\cdot\frac{283}{273+T}
$$

$R$ 是角分，参考波长 550 nm。视高度是 $h_{\mathrm{app}}(h)=h+R(h)$。水平半径仍是几何 $\rho$。视月面不用 $h+R(h)$ 当圆心，而用上下边缘的中点，这样压扁后的边缘和折射后的边缘一致：

$$
\begin{aligned}
h_c&=\bigl(h_{\mathrm{app}}(h+\rho)+h_{\mathrm{app}}(h-\rho)\bigr)/2\\
\rho_v&=\bigl(h_{\mathrm{app}}(h+\rho)-h_{\mathrm{app}}(h-\rho)\bigr)/2\\
s&=\rho_v/\rho
\end{aligned}
$$

$h_c$ 再夹进 $[-\pi/2,\pi/2]$。天顶附近 $s\approx 1$；真高度接近 0 时 $s<1$，月面沿天顶变扁。方位角不变。

色散用 Peck–Reeder 折射率。$\sigma=1/\lambda$，$\lambda$ 以 μm 计：

$$
(n-1)\,10^{8}=8342.13+\frac{2406030}{130-\sigma^{2}}+\frac{15997}{38.9-\sigma^{2}}
$$

波长取 650、550、450 nm。$R(\lambda)=R(h)\,(n(\lambda)-1)/(n(0.55)-1)$，其中 $R(h)$ 是几何月心的折射。红、蓝相对 550 nm 的高度差沿天顶平移，圆心仍是 550 nm。

消光用视圆心的高度。低于 $0^\circ$ 时大气质量按 $0^\circ$ 算，高于 $90^\circ$ 时按 $90^\circ$。Kasten–Young 大气质量里，括号外的高度是度，正弦用对应的弧度：

$$
X=\frac{1}{\sin h+0.50572\,(h+6.07995)^{-1.6364}}
$$

瑞利光学厚度（$\lambda$ 以 μm 计）再乘气压：

$$
\tau_R=0.008569\,\lambda^{-4}\bigl(1+0.0113\,\lambda^{-2}+0.00013\,\lambda^{-4}\bigr)\cdot P/1013.25
$$

### 气溶胶对视觉效果的影响模拟

当前版本晴空气溶胶不随气压变化， $\tau_{550}=0.12$。

Apple Developer Program（付费）用户可用 WeatherKit 获取当前能见度 $V$（千米）。

$$
\tau_{550}=\operatorname{clamp}(4.8/V,\ 0.05,\ 2.5)
$$

$40\,\mathrm{km}$ 为 $0.12$。

$$
\tau_a=\tau_{550}\,(\lambda/0.55)^{-1.3}
$$

透过率 $T=\exp\bigl(-(\tau_R+\tau_a)X\bigr)$。叠到精灵上的颜色是 $T(\lambda)/T(0.55)$，绿通道为 1，亮度留在反照率上。月亮低时大气质量 $X$ 变大，蓝/红下降，月面偏红。用户校正加在方位角和视高度 $h_c$ 上。

## 月相

先在赤道坐标里求月日角距 $\psi$。太阳用上一节的地心赤道坐标，月亮用站心赤经赤纬，距离仍用地心值。$\Delta_{\mathrm{AU}}=\Delta/149597870.7$。

$$
\cos\psi=\sin\delta_{\odot}\sin\delta'+\cos\delta_{\odot}\cos\delta'\cos(\alpha_{\odot}-\alpha')
$$

相位角 $i$ 是从月亮看太阳和观测者之间的夹角：

$$
i=\operatorname{atan2}(R\sin\psi,\ \Delta_{\mathrm{AU}}-R\cos\psi)
$$

亮面比例是圆盘上被照亮部分的投影面积比

$$
k=(1+\cos i)/2
$$

明暗界线亮缘中点的位置角是

$$
\chi=\operatorname{atan2}\bigl(\cos\delta_{\odot}\sin(\alpha_{\odot}-\alpha'),\ \sin\delta_{\odot}\cos\delta'-\cos\delta_{\odot}\sin\delta'\cos(\alpha_{\odot}-\alpha')\bigr)
$$

盈亏不看 $k$，而看地心黄经差。令 $E_{\lambda}=\mathrm{wrap}_{360}(\lambda-\lambda_{\odot})$，则 $E_{\lambda}<180^{\circ}$ 为盈。名称按 $k$ 划分：$\ge 0.98$ 为满月，$\le 0.02$ 为新月；盈月在 $0.35$、$0.65$ 处分成峨眉月、上弦月、盈凸月，亏月对应残月、下弦月、亏凸月。

## 天平动与轴位置角

月面朝向是几何模型：自转轴相对黄道倾斜 $I=1.54242^{\circ}$，指向由升交点决定，本初子午线用平黄经，不展开完整的光学天平动级数。黄道直角坐标里，月理北极和地心指向月亮的单位向量是

$$
\begin{aligned}
\mathbf{N}&=\operatorname{normalize}(-\sin I\sin\Omega,\ \sin I\cos\Omega,\ \cos I)\\
\mathbf{M}&=(\cos\beta\cos\lambda,\ \cos\beta\sin\lambda,\ \sin\beta)
\end{aligned}
$$

平均地球方向取在黄道面内、与平黄经相反：

$$
\mathbf{E}_{0}=(-\cos L',\ -\sin L',\ 0)
$$

把它投到垂直于 $\mathbf{N}$ 的平面上并归一化，得到月面本初子午线方向 $\mathbf{P}$。月面东方是 $\mathbf{E}=\operatorname{normalize}(\mathbf{N}\times\mathbf{P})$。从月心指向地球的方向是 $-\mathbf{M}$，于是

$$
\begin{aligned}
\beta_{\mathrm{lib}}&=\arcsin((-\mathbf{M})\cdot\mathbf{N})\\
\lambda_{\mathrm{lib}}&=\operatorname{atan2}((-\mathbf{M})\cdot\mathbf{E},\ (-\mathbf{M})\cdot\mathbf{P})
\end{aligned}
$$

轴位置角表示月理北极相对天北极、在月亮处的天空中偏了多少。把 $\mathbf{M}$ 和 $\mathbf{N}$ 用上一节的交角旋转变到赤道坐标，记为 $\mathbf{M}_{\mathrm{eq}}$、$\mathbf{N}_{\mathrm{eq}}$。天北极是 $(0,0,1)$。两者都减去沿 $\mathbf{M}_{\mathrm{eq}}$ 的分量，投到垂直于视线的平面上：

$$
\begin{aligned}
\mathbf{n}_{\star}&=\operatorname{normalize}\bigl((0,0,1)-\mathbf{M}_{\mathrm{eq}}\,[(0,0,1)\cdot\mathbf{M}_{\mathrm{eq}}]\bigr)\\
\mathbf{e}_{\star}&=\operatorname{normalize}(\mathbf{M}_{\mathrm{eq}}\times\mathbf{n}_{\star})\\
\mathbf{n}_{\mathrm{M}}&=\operatorname{normalize}(\mathbf{N}_{\mathrm{eq}}-\mathbf{M}_{\mathrm{eq}}\,(\mathbf{N}_{\mathrm{eq}}\cdot\mathbf{M}_{\mathrm{eq}}))
\end{aligned}
$$

$$
P=\operatorname{atan2}(\mathbf{n}_{\mathrm{M}}\cdot\mathbf{e}_{\star},\ \mathbf{n}_{\mathrm{M}}\cdot\mathbf{n}_{\star})
$$

投影长度小于 $10^{-8}$ 时 $P=0$。

## 月面怎么画

`MoonAlbedo.jpg` 是等距圆柱图：经度 $0$ 在图中央，北极在上。精灵图是 $2048\times2048$。像素 $(x,y)$ 先变成单位圆盘坐标，原点在图心，$+y$ 朝上：

$$
n_{x}=\frac{x-c}{c},\qquad n_{y}=\frac{c-y}{c},\qquad c=(2048-1)/2
$$

$n_{x}^{2}+n_{y}^{2}>1$ 的像素透明。圆内

$$
n_{z}=\sqrt{1-n_{x}^{2}-n_{y}^{2}}
$$

光照在这个朝向观测者的圆盘上计算，天平动只移动纹理，不改法线。亮缘相对月轴的角是 $\chi_{r}=\chi-P$。相位角为 $i$ 时，视线坐标里的太阳方向是

$$
\mathbf{s}=(-\sin\chi_{r}\sin i,\ \cos\chi_{r}\sin i,\ \cos i)
$$

它已经是单位向量。朗伯亮度是

$$
L=\max(0,\ \mathbf{n}\cdot\mathbf{s})
$$

阳面覆盖 $c_{\mathrm{sun}}=\mathrm{smoothstep}(0,0.05,L)$。交界这一小段把透明度收到 0，避免暗面留下黑边。暗面不和阳面相加，地照从观测者方向照来，朗伯项是 $n_z$。相位角 $i$ 和太阳高度决定的夜天权重 $w$ 合成系数

$$
g=w\cdot(1-\cos i)/2
$$

太阳高于 $6^\circ$ 时 $w=0$，低于 $-8^\circ$ 时 $w=1$，中间用同一段 smoothstep。$g$ 存在月亮状态里，校正偏差不改它。关掉「月相模拟」时 $i$ 和 $g$ 都按 0，整盘被照亮，没有灰光。暗面强度是

$$
E=0.12\,n_z\,g
$$

$0.12$ 是 8 位精灵上的可视增益。物理日地照比大约 $10^{-4}$，直接用会舍入成黑。边缘淡出 $f$ 照旧。透明度是

$$
\alpha=f\,c_{\mathrm{sun}}+fE\,(1-c_{\mathrm{sun}})
$$

预乘颜色在阳面是 $c\,L\,f\,c_{\mathrm{sun}}$，在暗面是 $c$ 乘暗面那一份透明度。

关闭「月相模拟」时渲染用的 $i$ 改为 0，于是 $\mathbf{s}=(0,0,1)$，整盘被照亮；$\chi$、$P$ 和天平动仍参与朝向。

采样前把圆盘点先绕 $Y$ 转 $-\lambda_{\mathrm{lib}}$，再绕 $X$ 转 $-\beta_{\mathrm{lib}}$：

$$
R_{y}(\theta)=\begin{pmatrix}\cos\theta&0&\sin\theta\\0&1&0\\-\sin\theta&0&\cos\theta\end{pmatrix},\qquad
R_{x}(\theta)=\begin{pmatrix}1&0&0\\0&\cos\theta&-\sin\theta\\0&\sin\theta&\cos\theta\end{pmatrix}
$$

$$
\mathbf{p}=R_{x}(-\beta_{\mathrm{lib}})\,R_{y}(-\lambda_{\mathrm{lib}})\,\mathbf{n}
$$

纹理经纬度是 $\lambda_{t}=\operatorname{atan2}(p_{x},p_{z})$、$\varphi_{t}=\arcsin(p_{y})$。图上的归一化坐标

$$
u=\frac12+\frac{\lambda_{t}}{2\pi},\qquad v=\frac12-\frac{\varphi_{t}}{\pi}
$$

$u$ 折进 $[0,1)$，$v$ 夹到 $[0,0.999999]$，再按图宽高做双线性插值。半径 $r=\sqrt{n_{x}^{2}+n_{y}^{2}}$ 在 $0.985$ 以内 $f=1$，最外 $1.5\%$ 线性淡出：

$$
f=\begin{cases}1&r<0.985\\\max\bigl(0,(1-r)/0.015\bigr)&\text{否则}\end{cases}
$$

$i$、$\chi$、$P$、$\lambda_{\mathrm{lib}}$、$\beta_{\mathrm{lib}}$ 各自换成度再乘 2，向零截成整数。$g$ 按 $0.05$ 一档取整。这六个量和「是否模拟月相」组成缓存键。角度相邻档大约相差 $0.5^{\circ}$。预览把精灵拆成红、绿、蓝三张通道图，绘制时做竖直缩放、绕天顶旋转，并沿天顶平移色散。

## 视场

采集格式优先使用几何畸变校正后的 4:3 横向视场角 $\mathrm{FOV}_{0}$（度，随即换成弧度），并在设备支持时打开几何畸变校正，使成像接近后面的直线投影。变焦不重新查表。$z=\max(\texttt{videoZoomFactor},0.01)$ 时

$$
\mathrm{FOV}_{x}(z)=2\arctan\bigl(\tan(\mathrm{FOV}_{0}/2)/z\bigr)
$$

4:3 的短边视场由长边推出：

$$
\mathrm{FOV}_{\mathrm{short}}=2\arctan\bigl(\tan(\mathrm{FOV}_{x}/2)\cdot 3/4\bigr)
$$

图像宽不小于高时，横向视场是长边、纵向是短边；竖幅则对调。界面上的变焦倍数是 $z$ 再乘 `displayVideoZoomFactorMultiplier`。

## 投到画面上

月亮单位向量 $\mathbf{m}=\mathbf{d}(A,h)$。深度是

$$
w=\mathbf{m}\cdot\mathbf{f}
$$

$w\le 0.02$ 时认为月亮在相机后方或贴近视场边缘之外，这一帧不放月面。否则切平面坐标是

$$
x=\frac{\mathbf{m}\cdot\mathbf{r}}{w},\qquad y=\frac{\mathbf{m}\cdot\mathbf{u}}{w}
$$

再除以半视场的正切，得到约在 $[-1,1]$ 的归一化坐标，最后换成像素。$y$ 向下：

$$
\begin{aligned}
n_{x}&=\frac{x}{\tan(\mathrm{FOV}_{x}/2)},&
n_{y}&=\frac{y}{\tan(\mathrm{FOV}_{y}/2)}\\
p_{x}&=\frac{n_{x}+1}{2}W,&
p_{y}&=\frac{1-n_{y}}{2}H
\end{aligned}
$$

像素半径用横向视场。水平半径是几何 $\rho$，竖直半径是 $s\rho$：

$$
r_{\mathrm{px}}=\frac{\tan\rho}{\tan(\mathrm{FOV}_{x}/2)}\cdot\frac{W}{2}
$$

月心落在画面外、且超出水平半径和竖直半径里较大的那个边距时，这一帧不放月面。色散的像素偏移用同一套比例，$\Delta h$ 是红或蓝相对 550 nm 的高度差，正方向朝天顶：

$$
d_{\mathrm{px}}=\frac{\tan\Delta h}{\tan(\mathrm{FOV}_{x}/2)}\cdot\frac{W}{2}
$$

精灵旋转让月理北极指向天空中的北。当地天北极在这套地平坐标里是 $\mathbf{d}(0,\varphi)$，纬度 $\varphi$ 即其高度角。把它投到垂直于光轴的平面：

$$
\mathbf{n}=\mathbf{d}(0,\varphi)-\mathbf{f}\,\bigl(\mathbf{d}(0,\varphi)\cdot\mathbf{f}\bigr)
$$

长度不小于 $10^{-6}$ 时，相对画面上方的顺时针角减去轴位置角：

$$
\psi_{\mathrm{sprite}}=\operatorname{atan2}(\mathbf{n}\cdot\mathbf{r},\ \mathbf{n}\cdot\mathbf{u})-P
$$

退化时 $\psi_{\mathrm{sprite}}=-P$。

天顶是世界坐标的 $+Z$。把它投到垂直于光轴的平面，用和天北极一样的方法得到相对画面上方的顺时针角 $\psi_Z$。投影长度小于 $10^{-6}$ 时 $\psi_Z=0$。绘制时先把月理北极转到相对天顶的角 $\psi_{\mathrm{sprite}}-\psi_Z$，再把竖直边乘 $s$，最后转回 $\psi_Z$。红、绿、蓝三张通道图沿天顶错开 $d_{\mathrm{px}}$，相加后再盖到画面上。

视高度满足 $h_c<-s\rho$，并且没有打开「地平线下仍绘制」时，预览不画月面。附近地景物几乎不被折射，仍以几何高度 0 为地平线，所以几何上已在地平线下、视上边缘仍露出的月亮会画出来。校正过程中不受这条约束。

月亮已经能被投影到画面内时不画箭头。否则仍用 $\mathbf{m}$ 求方向：若 $w>0.02$，归一化坐标与上面相同；否则不再除以深度，

$$
n_{x}=\frac{\mathbf{m}\cdot\mathbf{r}}{\tan(\mathrm{FOV}_{x}/2)},\qquad n_{y}=\frac{\mathbf{m}\cdot\mathbf{u}}{\tan(\mathrm{FOV}_{y}/2)}
$$

屏幕坐标 $s_{x}=n_{x}$、$s_{y}=-n_{y}$（$y$ 向下）。方向接近 0 时改成 $(0,1)$。箭头锚点是从画面中心沿 $(s_{x},s_{y})$ 走到内缩矩形的第一处。内缩是左 40、右 40、上 48、下 72。对每个朝向外侧的分量取

$$
t=\min\left\{\frac{b_{x}-c_{x}}{s_{x}},\frac{b_{y}-c_{y}}{s_{y}}\right\}
$$

其中 $b$ 是该分量指向的那条边，$c$ 是中心，只计入分母与行进方向同号的项。锚点是 $c+t(s_{x},s_{y})$。箭头旋转 $\operatorname{atan2}(s_{x},-s_{y})$，角距离是

$$
\gamma=\arccos\bigl(\operatorname{clamp}(w,-1,1)\bigr)
$$

月亮在身后时 $w<0$，$\gamma>90^{\circ}$。

反投影是投影的逆。像素 $(p_{x},p_{y})$ 先变回归一化坐标 $n_{x}=2p_{x}/W-1$、$n_{y}=1-2p_{y}/H$，再

$$
\mathbf{v}=\mathbf{f}+\mathbf{r}\,n_{x}\tan(\mathrm{FOV}_{x}/2)+\mathbf{u}\,n_{y}\tan(\mathrm{FOV}_{y}/2)
$$

然后用本节开头的反解从 $\mathbf{v}$ 得到 $(A,h)$。

## 校正

校正把误差写成方位角和高度角上的两个常数。松手点反投影得到 $(A_{\mathrm{ind}},h_{\mathrm{ind}})$，减去未经校正的历算 $(A_{0},h_{0})$：

$$
\begin{aligned}
\Delta A&=\mathrm{wrap}_{\pm 180}\bigl(\mathrm{deg}(A_{\mathrm{ind}}-A_{0})\bigr)\\
\Delta h&=\mathrm{deg}(h_{\mathrm{ind}}-h_{0})
\end{aligned}
$$

两个偏差以度存在 `UserDefaults`。之后每次投影和合成前先改正：

$$
A\leftarrow\mathrm{wrap}_{\pi}(A+\Delta A),\qquad h\leftarrow\operatorname{clamp}(h+\Delta h,-\pi/2,\pi/2)
$$

这里的 $\Delta A$、$\Delta h$ 已换成弧度。

## 拍照

按下快门时冻结已经加过偏差的月亮状态、当时的 $\mathbf{f},\mathbf{r},\mathbf{u}$，以及当时的横向视场角。照片转正之后，用成片的像素宽高把这份横向视场重新分成 $\mathrm{FOV}_{x}$、$\mathrm{FOV}_{y}$，再套用同一组投影公式。预览和成片共享视场角，像素网格不同，所以月面位置是按成片重算的。

合成时 Core Graphics 的原点在左下，投影的 $y$ 向下，因此

$$
y_{\mathrm{CG}}=H-p_{y}
$$

平移到 $(p_{x},y_{\mathrm{CG}})$ 后，沿天顶（Core Graphics 里 $y$ 向上）平移色散，旋转 $-\psi_Z$，竖直缩放 $s$，再旋转 $-(\psi_{\mathrm{sprite}}-\psi_Z)$。精灵画进边长 $2r_{\mathrm{px}}$ 的正方形，高度取负，用来把图像翻正。红、绿、蓝各画一次。合成像素取红色样本的 R、绿色样本的 G、蓝色样本的 B，乘上消光颜色后夹到该像素的不透明度。没有压扁、色散和偏色时画一次。保存时把拍摄经纬度写入照片。
